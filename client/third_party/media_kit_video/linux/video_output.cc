// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/video_output.h"
#include "include/media_kit_video/texture_gl.h"
#include "include/media_kit_video/texture_sw.h"

#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <epoxy/glx.h>
#include <gdk/gdkwayland.h>
#include <gdk/gdkx.h>

/* Lumeo patch. One of the buffers mpv draws into on the render thread.
   |texture| is a name in Flutter's share group, so the raster thread hands
   that same name to Flutter. |read_fence| is set by the raster thread, in
   its context, when it stops showing the buffer; the render thread waits on
   it before drawing into the buffer again, so a frame Flutter's GPU commands
   are still reading is never overwritten under them. */
typedef enum {
  FRAME_FREE,      /* Nobody's; the render thread may draw into it. */
  FRAME_RENDERING, /* The render thread is drawing into it. */
  FRAME_READY,     /* Finished; waiting for the raster thread to take it. */
  FRAME_SHOWN,     /* The raster thread's; sampled every composite. */
} FrameState;

typedef struct _Frame {
  FrameState state;
  guint32 fbo;
  guint32 texture;
  EGLSyncKHR read_fence;
  gint64 width;
  gint64 height;
} Frame;

/* One on screen, one finished and waiting for the next composite, one being
   drawn. With two, the render thread would wait for the raster thread to
   take the finished one before it could draw again. */
#define FRAME_COUNT 3

/* Lumeo patch: how far the H/W path has got. mpv's context can only be made
   once Flutter's is known, and that is on the raster thread's first
   composite of the texture. */
typedef enum {
  HW_WAITING,  /* No composite yet: Flutter's context is not known. */
  HW_SHARED,   /* mpv's context made in Flutter's share group. */
  HW_READY,    /* mpv's renderer made; frames flow. */
  HW_FAILED,   /* Could not; S/W takes over on the platform thread. */
} HwState;

struct _VideoOutput {
  GObject parent_instance;
  TextureGL* texture_gl;
  EGLDisplay egl_display; /* Flutter's, as the raster thread has it current. */
  EGLContext egl_context; /* mpv's, in Flutter's share group. */
  guint8* pixel_buffer;
  TextureSW* texture_sw;
  GMutex mutex; /* Only used in S/W rendering. */
  mpv_handle* handle;
  mpv_render_context* render_context;
  gint64 width;
  gint64 height;
  VideoOutputConfiguration configuration;
  TextureUpdateCallback texture_update_callback;
  gpointer texture_update_callback_context;
  FlTextureRegistrar* texture_registrar;
  gboolean destroyed;
  /* Lumeo patch: the render thread (H/W path). |frames_mutex| guards the
     frames, |width|, |height|, |update_pending|, |render_stop|, |hw_state|
     and |egl_context| until the render thread has it. */
  GThread* render_thread;
  GMutex frames_mutex;
  GCond frames_cond;
  gboolean update_pending; /* mpv's update callback fired. */
  gboolean redraw_pending; /* The size changed: draw the last frame again. */
  gboolean render_stop;
  gboolean fences; /* EGL_KHR_fence_sync is there. */
  HwState hw_state;
  /* What mpv's renderer is told about the windowing system, for hwdec
     interop; read on the platform thread, used on the render thread. */
  mpv_render_param_type display_param;
  gpointer display_data;
  Frame frames[FRAME_COUNT];
  gint ready;  /* Index into |frames|, or -1. */
  gint shown;  /* Index into |frames|, or -1. */
  /* mpv's video output cannot start without mpv's renderer ("No render
     context set"), so on the H/W path a client of our own holds every film
     in mpv's `on_load` hook until the renderer is there. |load_mutex|
     guards |load_ready| and |load_stop|. */
  mpv_handle* load_client;
  GThread* load_thread;
  GMutex load_mutex;
  GCond load_cond;
  gboolean load_ready;
  gboolean load_stop;
};

G_DEFINE_TYPE(VideoOutput, video_output, G_TYPE_OBJECT)

static void video_output_fall_back_to_sw(VideoOutput* self);
static void video_output_let_films_load(VideoOutput* self);

static void video_output_dispose(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  self->destroyed = TRUE;

  // H/W
  if (self->texture_gl) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_gl));
  }
  /* Lumeo patch. Flutter has let go of the texture, so no composite comes
     for the frames again; now the render thread, which owns mpv's context,
     mpv's renderer and the frames, frees them and releases the context on
     its way out. It is joined even after a fall back to S/W: it has
     returned by then, and a GThread is freed by its join. */
  if (self->render_thread != NULL) {
    g_mutex_lock(&self->frames_mutex);
    self->render_stop = TRUE;
    g_cond_broadcast(&self->frames_cond);
    g_mutex_unlock(&self->frames_mutex);
    g_thread_join(self->render_thread);
    self->render_thread = NULL;
  }
  g_mutex_lock(&self->frames_mutex);
  self->render_stop = TRUE;
  if (self->egl_context != EGL_NO_CONTEXT) {
    eglDestroyContext(self->egl_display, self->egl_context);
    self->egl_context = EGL_NO_CONTEXT;
  }
  g_mutex_unlock(&self->frames_mutex);
  g_clear_object(&self->texture_gl);
  // S/W
  if (self->texture_sw) {
    if (self->render_context) {
      mpv_render_context_set_update_callback(self->render_context, NULL, NULL);
    }
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_sw));
    g_free(self->pixel_buffer);
    self->pixel_buffer = NULL;
    g_clear_object(&self->texture_sw);
    if (self->render_context != NULL) {
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
    }
  }
  /* A film held in the hook is let go: the renderer will not come, and a
     held hook would keep mpv from stopping or quitting. */
  if (self->load_thread != NULL) {
    g_mutex_lock(&self->load_mutex);
    self->load_stop = TRUE;
    g_cond_broadcast(&self->load_cond);
    if (self->load_client != NULL) {
      mpv_wakeup(self->load_client);
    }
    g_mutex_unlock(&self->load_mutex);
    g_thread_join(self->load_thread);
    self->load_thread = NULL;
  }
  if (self->load_client != NULL) {
    mpv_destroy(self->load_client);
    self->load_client = NULL;
  }

  G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
}

static void video_output_finalize(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  g_mutex_clear(&self->load_mutex);
  g_cond_clear(&self->load_cond);
  g_mutex_clear(&self->mutex);
  g_mutex_clear(&self->frames_mutex);
  g_cond_clear(&self->frames_cond);
  G_OBJECT_CLASS(video_output_parent_class)->finalize(object);
}

static void video_output_class_init(VideoOutputClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = video_output_dispose;
  G_OBJECT_CLASS(klass)->finalize = video_output_finalize;
}

static void video_output_init(VideoOutput* self) {
  self->texture_gl = NULL;
  self->egl_display = EGL_NO_DISPLAY;
  self->egl_context = EGL_NO_CONTEXT;
  self->texture_sw = NULL;
  self->pixel_buffer = NULL;
  self->handle = NULL;
  self->render_context = NULL;
  self->width = 0;
  self->height = 0;
  self->configuration = VideoOutputConfiguration{};
  self->texture_update_callback = NULL;
  self->texture_update_callback_context = NULL;
  self->texture_registrar = NULL;
  self->destroyed = FALSE;
  g_mutex_init(&self->mutex);
  self->render_thread = NULL;
  g_mutex_init(&self->frames_mutex);
  g_cond_init(&self->frames_cond);
  self->update_pending = FALSE;
  self->redraw_pending = FALSE;
  self->render_stop = FALSE;
  self->fences = FALSE;
  self->hw_state = HW_WAITING;
  self->display_param = MPV_RENDER_PARAM_INVALID;
  self->display_data = NULL;
  for (gint i = 0; i < FRAME_COUNT; i++) {
    self->frames[i] = Frame{FRAME_FREE, 0, 0, EGL_NO_SYNC_KHR, 0, 0};
  }
  self->ready = -1;
  self->shown = -1;
  self->load_client = NULL;
  self->load_thread = NULL;
  g_mutex_init(&self->load_mutex);
  g_cond_init(&self->load_cond);
  self->load_ready = FALSE;
  self->load_stop = FALSE;
}

/* Lumeo patch. Upstream's S/W render, out of its idle callback so that
   |video_output_set_size| can run it too: the frames mpv announced before the
   size arrived were skipped at 0x0, and a paused film has no next frame to
   announce. Platform thread only. */
static void video_output_render_sw(VideoOutput* self) {
  if (self->destroyed || self->texture_sw == NULL ||
      self->render_context == NULL) {
    return;
  }
  g_mutex_lock(&self->mutex);
  gint64 width = video_output_get_width(self);
  gint64 height = video_output_get_height(self);
  if (width > 0 && height > 0) {
    gint32 size[]{(gint32)width, (gint32)height};
    gint32 pitch = 4 * (gint32)width;
    mpv_render_param params[]{
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, (void*)"rgb0"},
        {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
        {MPV_RENDER_PARAM_SW_POINTER, self->pixel_buffer},
        {MPV_RENDER_PARAM_INVALID, (void*)0},
    };
    mpv_render_context_render(self->render_context, params);
    fl_texture_registrar_mark_texture_frame_available(
        self->texture_registrar, FL_TEXTURE(self->texture_sw));
  }
  g_mutex_unlock(&self->mutex);
}


/* Lumeo patch. The render thread.

   mpv's render.h asks for rendering on a thread of its own, one that never
   waits for anything the core holds; upstream rendered on Flutter's raster
   thread instead, which is also the thread that draws every widget. mpv holds
   |mpv_render_context_render| until the frame's display time, and its video
   output waits up to 200 ms for the call to come; during a seek storm the
   raster thread sat in both, and the scrubber's thumb — pure Dart — stood
   still with the picture. Now this thread owns mpv's context and is the one
   mpv holds, and the raster thread only picks up what is finished.

   Frames go round three buffers, see |Frame|. mpv's context is made in
   Flutter's share group, so a buffer's texture is a name Flutter can sample
   as it is: the finished frame is |glFinish|ed here before it is announced,
   and a buffer is drawn into again only after the fence Flutter's thread
   set on it has passed.

   Shared, not joined by an EGLImage between two unshared contexts, which is
   what upstream 2.0 does because Flutter 3.38 stopped handing plugins a GDK
   context to share. On NVIDIA/Wayland, after the window had been hidden,
   one buffer's EGLImage stopped seeing mpv's writes: the screen flashed the
   same old frame every third frame while mpv went on drawing new ones, and
   reallocating the buffers (a change of the film's aspect ratio from mpv's
   console) cured it at once. With one share group there is no second copy
   of a buffer to fall behind. */

/* Render thread, mpv's context current. */
static void frame_free(VideoOutput* self, Frame* frame) {
  if (frame->read_fence != EGL_NO_SYNC_KHR) {
    eglDestroySyncKHR(self->egl_display, frame->read_fence);
    frame->read_fence = EGL_NO_SYNC_KHR;
  }
  if (frame->fbo != 0) {
    glDeleteFramebuffers(1, &frame->fbo);
    frame->fbo = 0;
  }
  if (frame->texture != 0) {
    glDeleteTextures(1, &frame->texture);
    frame->texture = 0;
  }
  frame->width = frame->height = 0;
}

/* Render thread, mpv's context current. A texture of the given size with an
   FBO over it. */
static void frame_allocate(VideoOutput* self,
                           Frame* frame,
                           gint64 width,
                           gint64 height) {
  frame_free(self, frame);
  glGenFramebuffers(1, &frame->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, frame->fbo);
  glGenTextures(1, &frame->texture);
  glBindTexture(GL_TEXTURE_2D, frame->texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, NULL);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         frame->texture, 0);
  glBindTexture(GL_TEXTURE_2D, 0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  frame->width = width;
  frame->height = height;
}

/* Render thread. mpv has a frame (or a redraw) for us: draw it into a free
   buffer, hold it until its display time, hand it to the raster thread. */
static void video_output_render_frame(VideoOutput* self) {
  g_mutex_lock(&self->frames_mutex);
  gint64 width = self->width;
  gint64 height = self->height;
  gint slot = -1;
  for (gint i = 0; i < FRAME_COUNT; i++) {
    if (self->frames[i].state == FRAME_FREE) {
      slot = i;
      break;
    }
  }
  /* One shown, one ready, one drawn: a free one always exists. */
  g_assert(slot >= 0);
  Frame* frame = &self->frames[slot];
  frame->state = FRAME_RENDERING;
  EGLSyncKHR read_fence = frame->read_fence;
  frame->read_fence = EGL_NO_SYNC_KHR;
  g_mutex_unlock(&self->frames_mutex);

  /* Flutter's GPU commands that sampled this buffer, done. The fence was
     flushed when it was set, so this waits on work already submitted; a
     second is a stuck GPU, not a slow one. Then the buffer stays Flutter's,
     the fence goes back on it, and this frame is taken without drawing. */
  gboolean writable = TRUE;
  if (read_fence != EGL_NO_SYNC_KHR) {
    if (eglClientWaitSyncKHR(self->egl_display, read_fence, 0,
                             G_GINT64_CONSTANT(1000000000) /* ns */) ==
        EGL_TIMEOUT_EXPIRED_KHR) {
      g_printerr("media_kit: VideoOutput: Flutter has not finished reading a "
                 "frame in a second; skipping a frame.\n");
      writable = FALSE;
    } else {
      eglDestroySyncKHR(self->egl_display, read_fence);
      read_fence = EGL_NO_SYNC_KHR;
    }
  }

  gboolean drawn = writable && width > 0 && height > 0;
  if (drawn && (frame->width != width || frame->height != height)) {
    frame_allocate(self, frame, width, height);
  }
  gint skip = drawn ? 0 : 1;
  /* mpv holds this call until the frame's display time — the default, and
     what render.h means by rendering on a thread of its own: this thread is
     the one kept, nobody else. It is also the only clock that is right:
     NEXT_FRAME_INFO's |target_time| is documented in microseconds and has
     been the video output's nanosecond |pts| since mpv 0.36 (vo_libmpv.c
     hands it over unconverted), and a wait computed from it never ends. The
     hold is bounded by mpv itself: its video output releases the call at the
     frame's time, or after its own 200 ms timeout if it never came to it.
     No size yet (the film's dimensions have not arrived from the Dart side)
     or no buffer to draw into means the frame is taken and not drawn, so
     mpv's video output does not sit waiting for a render that never comes;
     mpv keeps the frame and redraws it on request. */
  gint block = 1;
  mpv_opengl_fbo fbo{(gint32)frame->fbo, (gint32)width, (gint32)height, 0};
  gint flip_y = 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
      {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
      {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
      {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  glBindFramebuffer(GL_FRAMEBUFFER, frame->fbo);
  mpv_render_context_render(self->render_context, params);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (drawn) {
    /* The frame is *finished* before the other context samples it: a change
       to a shared object is guaranteed visible to another context only once
       it has completed there (GLES 3.2, appendix D), and glFlush would only
       say the commands were submitted. */
    glFinish();
  }

  g_mutex_lock(&self->frames_mutex);
  if (drawn) {
    if (self->ready >= 0) {
      /* Finished, never shown, and now superseded: Flutter did not come for
         it in time, which is what dropping a frame here looks like. */
      self->frames[self->ready].state = FRAME_FREE;
    }
    frame->state = FRAME_READY;
    self->ready = slot;
  } else {
    frame->state = FRAME_FREE;
    frame->read_fence = read_fence;
  }
  g_mutex_unlock(&self->frames_mutex);

  if (drawn) {
    fl_texture_registrar_mark_texture_frame_available(
        self->texture_registrar, FL_TEXTURE(self->texture_gl));
  }
}

static void video_output_wake_render_thread(VideoOutput* self,
                                            gboolean redraw);
static void video_output_post_to_platform(VideoOutput* self);

/* Render thread. Waits for mpv's context, made on the raster thread by
   |video_output_share_context|, takes it for good and makes mpv's renderer
   in it. FALSE when stopped first or when either could not be made; the
   latter leaves |hw_state| at HW_FAILED. */
static gboolean video_output_render_thread_start(VideoOutput* self) {
  g_mutex_lock(&self->frames_mutex);
  while (self->hw_state == HW_WAITING && !self->render_stop) {
    g_cond_wait(&self->frames_cond, &self->frames_mutex);
  }
  gboolean shared = self->hw_state == HW_SHARED && !self->render_stop;
  g_mutex_unlock(&self->frames_mutex);
  if (!shared) {
    return FALSE;
  }
  gboolean made = FALSE;
  if (!eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                      self->egl_context)) {
    g_printerr("media_kit: VideoOutput: render thread: eglMakeCurrent failed: 0x%x\n",
               eglGetError());
  } else {
    mpv_opengl_init_params gl_init_params{
        [](auto, auto name) { return (void*)eglGetProcAddress(name); },
        NULL,
    };
    /* This thread keeps render.h's advanced-control rules: it calls
       mpv_render_context_update on every wake and never waits for the core.
       Without the flag mpv takes screenshots in software, which cannot read
       a hardware frame on mpv 0.41 (fixed upstream in c66204b69b). */
    gint advanced_control = 1;
    /* VAAPI acceleration requires passing X11/Wayland display. */
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, (void*)&gl_init_params},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
        {self->display_param, self->display_data},
        {MPV_RENDER_PARAM_INVALID, (void*)0},
    };
    if (mpv_render_context_create(&self->render_context, self->handle,
                                  params) == 0) {
      mpv_render_context_set_update_callback(
          self->render_context,
          [](void* data) {
            video_output_wake_render_thread((VideoOutput*)data, FALSE);
          },
          self);
      self->fences =
          epoxy_has_egl_extension(self->egl_display, "EGL_KHR_fence_sync");
      if (!self->fences) {
        g_printerr("media_kit: VideoOutput: no EGL_KHR_fence_sync; "
                   "frames are reused without waiting for Flutter.\n");
      }
      g_print("media_kit: VideoOutput: H/W rendering in Flutter's share group.\n");
      made = TRUE;
    } else {
      g_printerr("media_kit: VideoOutput: Failed to create mpv_render_context.\n");
      self->render_context = NULL;
      eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                     EGL_NO_CONTEXT);
    }
  }
  g_mutex_lock(&self->frames_mutex);
  self->hw_state = made ? HW_READY : HW_FAILED;
  g_mutex_unlock(&self->frames_mutex);
  return made;
}

static gpointer video_output_render_thread(gpointer data) {
  VideoOutput* self = VIDEO_OUTPUT(data);
  gboolean started = video_output_render_thread_start(self);
  g_mutex_lock(&self->frames_mutex);
  gboolean stopped = self->render_stop;
  g_mutex_unlock(&self->frames_mutex);
  if (!stopped) {
    /* Ready for the film, or S/W has to take over: the platform thread's
       business either way. */
    video_output_post_to_platform(self);
  }
  if (!started) {
    return NULL;
  }
  g_mutex_lock(&self->frames_mutex);
  while (!self->render_stop) {
    if (!self->update_pending && !self->redraw_pending) {
      g_cond_wait(&self->frames_cond, &self->frames_mutex);
      continue;
    }
    gboolean update = self->update_pending;
    gboolean redraw = self->redraw_pending;
    self->update_pending = self->redraw_pending = FALSE;
    g_mutex_unlock(&self->frames_mutex);
    /* Not from the update callback itself, render.h insists. Rendering with
       no new frame draws mpv's last one again, which is what a resize needs. */
    guint64 flags = update ? mpv_render_context_update(self->render_context) : 0;
    if ((flags & MPV_RENDER_UPDATE_FRAME) || redraw) {
      video_output_render_frame(self);
    }
    g_mutex_lock(&self->frames_mutex);
  }
  for (gint i = 0; i < FRAME_COUNT; i++) {
    frame_free(self, &self->frames[i]);
    self->frames[i].state = FRAME_FREE;
  }
  self->ready = self->shown = -1;
  g_mutex_unlock(&self->frames_mutex);
  /* mpv's renderer goes with the context it was made in, on the thread that
     has it current. No update callback may come once it is being freed. */
  mpv_render_context_set_update_callback(self->render_context, NULL, NULL);
  mpv_render_context_free(self->render_context);
  self->render_context = NULL;
  eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                 EGL_NO_CONTEXT);
  return NULL;
}

/* Any thread. */
static void video_output_wake_render_thread(VideoOutput* self,
                                            gboolean redraw) {
  g_mutex_lock(&self->frames_mutex);
  if (redraw) {
    self->redraw_pending = TRUE;
  } else {
    self->update_pending = TRUE;
  }
  g_cond_broadcast(&self->frames_cond);
  g_mutex_unlock(&self->frames_mutex);
}

/* Raster thread, Flutter's context current: the first composite of the
   texture. That context is Flutter's own render context (the embedder makes
   it current for every raster task), the root of its share group, so mpv's
   context is made here, sharing with it, with the same config and
   attributes Flutter gives its own resource and platform contexts
   (fl_opengl_manager.cc). Nothing else identifies the share group: Flutter
   hands plugins no context, and what is current on the platform thread
   depends on who drew last — GDK makes its own context current there. */
void video_output_share_context(VideoOutput* self) {
  g_mutex_lock(&self->frames_mutex);
  /* Not once the output is being disposed: a composite already inside
     populate can outlive the unregistering, and a context made then would
     never be destroyed. */
  if (self->hw_state != HW_WAITING || self->render_stop) {
    g_mutex_unlock(&self->frames_mutex);
    return;
  }
  EGLDisplay display = eglGetCurrentDisplay();
  EGLContext flutter_context = eglGetCurrentContext();
  EGLContext context = EGL_NO_CONTEXT;
  EGLConfig config = NULL;
  if (display == EGL_NO_DISPLAY || flutter_context == EGL_NO_CONTEXT) {
    g_printerr("media_kit: VideoOutput: no EGL context on Flutter's raster thread.\n");
  } else {
    EGLint config_id = 0;
    EGLint configs = 0;
    if (!eglQueryContext(display, flutter_context, EGL_CONFIG_ID, &config_id)) {
      g_printerr("media_kit: VideoOutput: Failed to query Flutter's EGL config ID.\n");
    } else {
      EGLint config_attribs[] = {EGL_CONFIG_ID, config_id, EGL_NONE};
      if (!eglChooseConfig(display, config_attribs, &config, 1, &configs) ||
          configs == 0) {
        g_printerr("media_kit: VideoOutput: Failed to get Flutter's EGL config by ID.\n");
        config = NULL;
      }
    }
  }
  if (config != NULL) {
    EGLint context_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    context = eglCreateContext(display, config, flutter_context,
                               context_attribs);
    if (context == EGL_NO_CONTEXT) {
      g_printerr("media_kit: VideoOutput: Failed to create an EGL context "
                 "shared with Flutter's: 0x%x\n",
                 eglGetError());
    }
  }
  if (context != EGL_NO_CONTEXT) {
    self->egl_display = display;
    self->egl_context = context;
    self->hw_state = HW_SHARED;
  } else {
    self->hw_state = HW_FAILED;
  }
  g_cond_broadcast(&self->frames_cond);
  g_mutex_unlock(&self->frames_mutex);
}

/* Raster thread, Flutter's context current. */
gboolean video_output_take_frame(VideoOutput* self, VideoFrame* out) {
  g_mutex_lock(&self->frames_mutex);
  if (self->ready >= 0) {
    if (self->shown >= 0) {
      Frame* shown = &self->frames[self->shown];
      /* Everything Flutter issued against this buffer is already in its
         command stream — the previous composite is done being recorded —
         so a fence here is the point after its last read. */
      if (self->fences) {
        shown->read_fence =
            eglCreateSyncKHR(self->egl_display, EGL_SYNC_FENCE_KHR, NULL);
        glFlush();
      }
      shown->state = FRAME_FREE;
    }
    self->shown = self->ready;
    self->ready = -1;
    self->frames[self->shown].state = FRAME_SHOWN;
  }
  gboolean have = self->shown >= 0;
  if (have) {
    /* The buffer's own texture: one share group, one name. Flutter wraps it
       afresh for every frame it takes, which is the rebinding a change made
       in another context needs to be seen. The render thread deletes it
       only once it is no longer shown and its fence has passed. */
    Frame* frame = &self->frames[self->shown];
    *out = VideoFrame{frame->texture, frame->width, frame->height};
  }
  g_mutex_unlock(&self->frames_mutex);
  return have;
}

/* Render thread, to the platform thread: the H/W path is ready, or has
   failed and S/W takes over. By weak reference: the output may be disposed
   before the idle runs, and then there is nobody to tell. */
static gboolean video_output_on_platform(gpointer data) {
  GWeakRef* ref = (GWeakRef*)data;
  VideoOutput* self = VIDEO_OUTPUT(g_weak_ref_get(ref));
  g_weak_ref_clear(ref);
  g_free(ref);
  if (self == NULL) {
    return G_SOURCE_REMOVE;
  }
  if (!self->destroyed) {
    g_mutex_lock(&self->frames_mutex);
    gboolean failed = self->hw_state == HW_FAILED;
    g_mutex_unlock(&self->frames_mutex);
    if (failed) {
      video_output_fall_back_to_sw(self);
    }
    video_output_let_films_load(self);
  }
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

static void video_output_post_to_platform(VideoOutput* self) {
  GWeakRef* ref = g_new0(GWeakRef, 1);
  g_weak_ref_init(ref, self);
  g_idle_add(video_output_on_platform, ref);
}

/* Any thread: films may load from now on. */
static void video_output_let_films_load(VideoOutput* self) {
  g_mutex_lock(&self->load_mutex);
  self->load_ready = TRUE;
  g_cond_broadcast(&self->load_cond);
  g_mutex_unlock(&self->load_mutex);
}

/* The load client's thread: every `on_load` is held until the renderer is
   there (or the output goes), then continued. mpv's own mechanism for a
   client that has to prepare before a file is opened; nothing on the Dart
   side waits, so closing the player before the first composite — the window
   hidden, or the screen left at once — stops mpv as it always did. */
static gpointer video_output_load_thread(gpointer data) {
  VideoOutput* self = VIDEO_OUTPUT(data);
  gboolean stop = FALSE;
  while (!stop) {
    mpv_event* event = mpv_wait_event(self->load_client, -1);
    if (event->event_id == MPV_EVENT_SHUTDOWN) {
      /* The core waits for every client, weak ones too, before it can go:
         let go of it now rather than at dispose. */
      g_mutex_lock(&self->load_mutex);
      mpv_destroy(self->load_client);
      self->load_client = NULL;
      g_mutex_unlock(&self->load_mutex);
      break;
    }
    if (event->event_id == MPV_EVENT_HOOK) {
      guint64 id = ((mpv_event_hook*)event->data)->id;
      g_mutex_lock(&self->load_mutex);
      while (!self->load_ready && !self->load_stop) {
        g_cond_wait(&self->load_cond, &self->load_mutex);
      }
      g_mutex_unlock(&self->load_mutex);
      mpv_hook_continue(self->load_client, id);
    }
    g_mutex_lock(&self->load_mutex);
    stop = self->load_stop;
    g_mutex_unlock(&self->load_mutex);
  }
  return NULL;
}

/* Platform thread. Upstream's S/W setup, out of |video_output_new| so that
   a failed H/W start can fall back to it too. */
static void video_output_init_sw(VideoOutput* self) {
#ifdef MPV_RENDER_API_TYPE_SW
  g_printerr("media_kit: VideoOutput: S/W rendering.\n");
  self->width = CLAMP(self->width, 0, SW_RENDERING_MAX_WIDTH);
  self->height = CLAMP(self->height, 0, SW_RENDERING_MAX_HEIGHT);
  self->pixel_buffer = g_new0(guint8, SW_RENDERING_PIXEL_BUFFER_SIZE);
  self->texture_sw = texture_sw_new(self);
  if (fl_texture_registrar_register_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_sw))) {
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_INVALID, (void*)0},
    };
    if (mpv_render_context_create(&self->render_context, self->handle,
                                  params) == 0) {
      mpv_render_context_set_update_callback(
          self->render_context,
          [](void* data) {
            gdk_threads_add_idle(
                [](gpointer data) -> gboolean {
                  video_output_render_sw((VideoOutput*)data);
                  return FALSE;
                },
                data);
          },
          self);
    }
  }
#else
  g_printerr("media_kit: VideoOutput: no H/W rendering, and S/W rendering "
             "is not supported.\n");
#endif
}

/* Platform thread: the render thread could not start. Flutter gets a new
   texture, and the Dart side its id with the next size notice. */
static void video_output_fall_back_to_sw(VideoOutput* self) {
  fl_texture_registrar_unregister_texture(self->texture_registrar,
                                          FL_TEXTURE(self->texture_gl));
  g_clear_object(&self->texture_gl);
  video_output_init_sw(self);
  if (self->texture_sw != NULL && self->texture_update_callback != NULL) {
    video_output_notify_texture_update(
        self, self->width > 0 ? self->width : 1,
        self->height > 0 ? self->height : 1);
  }
  video_output_render_sw(self);
}

VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration) {
  VideoOutput* self = VIDEO_OUTPUT(g_object_new(video_output_get_type(), NULL));
  self->texture_registrar = texture_registrar;
  self->handle = (mpv_handle*)handle;
  self->width = configuration.width;
  self->height = configuration.height;
  self->configuration = configuration;
#ifndef MPV_RENDER_API_TYPE_SW
  // MPV_RENDER_API_TYPE_SW must be available for S/W rendering.
  if (!self->configuration.enable_hardware_acceleration) {
    g_printerr("media_kit: VideoOutput: S/W rendering is not supported.\n");
  }
  self->configuration.enable_hardware_acceleration = TRUE;
#endif
  mpv_set_option_string(self->handle, "video-sync", "audio");
  // Causes frame drops with `pulse` audio output. (SlotSun/dart_simple_live#42)
  // mpv_set_option_string(self->handle, "video-timing-offset", "0");
  /* Lumeo patch. The H/W path is only started here: mpv's context has to be
     in Flutter's share group, and Flutter's context is known on the raster
     thread's first composite of the texture (|video_output_share_context|).
     The render thread makes mpv's renderer then, and until it is there
     films wait in mpv's `on_load` hook (|video_output_load_thread|). */
  if (self->configuration.enable_hardware_acceleration) {
    GdkDisplay* display = gdk_display_get_default();
    if (GDK_IS_WAYLAND_DISPLAY(display)) {
      self->display_param = MPV_RENDER_PARAM_WL_DISPLAY;
      self->display_data = gdk_wayland_display_get_wl_display(display);
    } else if (GDK_IS_X11_DISPLAY(display)) {
      self->display_param = MPV_RENDER_PARAM_X11_DISPLAY;
      self->display_data = gdk_x11_display_get_xdisplay(display);
    }
    self->texture_gl = texture_gl_new(self);
    if (fl_texture_registrar_register_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_gl))) {
      /* Weak: the core's life stays media_kit's business. */
      self->load_client = mpv_create_weak_client(self->handle, "lumeo_video");
      if (self->load_client == NULL ||
          mpv_hook_add(self->load_client, 0, "on_load", 0) < 0) {
        g_printerr("media_kit: VideoOutput: could not hold films until the "
                   "renderer is ready.\n");
      } else {
        self->load_thread =
            g_thread_new("mpv-load", video_output_load_thread, self);
      }
      self->render_thread =
          g_thread_new("mpv-render", video_output_render_thread, self);
      return self;
    }
    g_printerr("media_kit: VideoOutput: Failed to register texture.\n");
    g_clear_object(&self->texture_gl);
  }
  video_output_init_sw(self);
  return self;
}

void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context) {
  self->texture_update_callback = texture_update_callback;
  self->texture_update_callback_context = texture_update_callback_context;
  // Notify initial dimensions as (1, 1) if |width| & |height| are 0 i.e.
  // texture & video frame size is based on playing file's resolution. This
  // will make sure that `Texture` widget on Flutter's widget tree is actually
  // mounted & |fl_texture_registrar_mark_texture_frame_available| actually
  // invokes the |TextureGL| or |TextureSW| callbacks. Otherwise it will be a
  // never ending deadlock where no video frames are ever rendered.
  gint64 texture_id = video_output_get_texture_id(self);
  if (self->width == 0 || self->height == 0) {
    self->texture_update_callback(texture_id, 1, 1,
                                  self->texture_update_callback_context);
  } else {
    self->texture_update_callback(texture_id, self->width, self->height,
                                  self->texture_update_callback_context);
  }
}

void video_output_set_size(VideoOutput* self, gint64 width, gint64 height) {
  // Ideally, a mutex should be used here & |video_output_get_width| +
  // |video_output_get_height|. However, that is throwing everything into a
  // deadlock. Flutter itself seems to have some synchronization mechanism in
  // rendering & platform channels AFAIK.
  gint64 before_width = self->width;
  gint64 before_height = self->height;

  // H/W
  if (self->texture_gl) {
    /* Lumeo patch: the render thread reads both under this mutex, so it
       never sees one axis of the old size with the other of the new. */
    g_mutex_lock(&self->frames_mutex);
    self->width = width;
    self->height = height;
    g_mutex_unlock(&self->frames_mutex);
  }
  // S/W
  if (self->texture_sw) {
    self->width = CLAMP(width, 0, SW_RENDERING_MAX_WIDTH);
    self->height = CLAMP(height, 0, SW_RENDERING_MAX_HEIGHT);
  }

  /* Lumeo patch. The frames mpv announced before this size arrived were
     drawn against no size at all, so nothing was drawn. Ask for one more
     render — mpv redraws its last frame when it has no new one — so the
     first frame of a film is shown even when mpv has no second frame to
     announce; a film paused on its opening frame would otherwise sit on the
     placeholder. */
  if (self->destroyed ||
      (self->width == before_width && self->height == before_height)) {
    return;
  }
  if (self->texture_gl != NULL) {
    video_output_wake_render_thread(self, TRUE);
  } else {
    video_output_render_sw(self);
  }
}

mpv_render_context* video_output_get_render_context(VideoOutput* self) {
  return self->render_context;
}

EGLDisplay video_output_get_egl_display(VideoOutput* self) {
  return self->egl_display;
}

EGLContext video_output_get_egl_context(VideoOutput* self) {
  return self->egl_context;
}

guint8* video_output_get_pixel_buffer(VideoOutput* self) {
  return self->pixel_buffer;
}

/* Lumeo patch. Upstream asked mpv for `video-out-params` here, with
   |mpv_get_property| — which is synchronous: it hands the question to mpv's
   core thread and waits for it. These two are called by
   |texture_gl_populate_texture| twice for every composited frame, on
   Flutter's raster thread — the only thread that ever calls
   |mpv_render_context_render|, and therefore the thread `vo_libmpv` waits on
   in flip_page while the core feeds it. The core waits for the video output,
   the video output waits for the render call, the render call waits for the
   core: the picture stops while the audio, on its own thread, goes on.

   Moving the question to the platform thread (an idle queued from the update
   callback) did not help, and was what the first version of this patch did:
   Flutter runs Dart's UI isolate on that same thread, so every frame held
   Dart for as long as the core was busy — and the core is busiest exactly
   during a seek, when the frames come fastest. Every key, click and drag was
   then answered late, and a `keyup` delivered late is a key mpv holds and
   auto-repeats.

   So nothing here asks mpv anything. The size is the one the Dart side sends
   through `VideoOutputManager.SetSize`: `NativeVideoController` observes
   `video-params` from mpv's own event loop, where no thread waits, and sends
   `dw`x`dh` (rotation applied) for every film. Until it arrives the size is
   0x0 and the texture is the 1x1 placeholder, which is the wait for the first
   frame in any case. */
gint64 video_output_get_width(VideoOutput* self) {
  return self->width;
}

gint64 video_output_get_height(VideoOutput* self) {
  return self->height;
}

gint64 video_output_get_texture_id(VideoOutput* self) {
  // H/W
  if (self->texture_gl) {
    return (gint64)self->texture_gl;
  }
  // S/W
  if (self->texture_sw) {
    return (gint64)self->texture_sw;
  }
  g_assert_not_reached();
  return -1;
}

void video_output_notify_texture_update(VideoOutput* self,
                                        gint64 width,
                                        gint64 height) {
  gint64 id = video_output_get_texture_id(self);
  gpointer context = self->texture_update_callback_context;
  if (self->texture_update_callback != NULL) {
    self->texture_update_callback(id, width, height, context);
  }
}
