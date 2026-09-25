// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/texture_gl.h"

#include <epoxy/gl.h>
#include <epoxy/egl.h>

/* Lumeo patch. Upstream rendered mpv's frame from inside |populate|, on
   Flutter's raster thread; that moved to a thread of its own in
   video_output.cc, and so did the buffers and the textures over them. What
   is left here is Flutter's texture object: on the first composite, let
   mpv's context be made in the share group of Flutter's, current here; then
   ask for the latest finished frame, or show the placeholder until there is
   one. */

struct _TextureGL {
  FlTextureGL parent_instance;
  guint32 placeholder; /* 1x1, shown until the first frame. */
  guint32 current_width;
  guint32 current_height;
  VideoOutput* video_output;
};

G_DEFINE_TYPE(TextureGL, texture_gl, fl_texture_gl_get_type())

static void texture_gl_init(TextureGL* self) {
  self->placeholder = 0;
  self->current_width = 1;
  self->current_height = 1;
  self->video_output = NULL;
}

static void texture_gl_dispose(GObject* object) {
  TextureGL* self = TEXTURE_GL(object);
  /* The placeholder, in whatever context is current — as upstream did with
     its one name. The frames' textures are the render thread's. */
  if (self->placeholder != 0) {
    glDeleteTextures(1, &self->placeholder);
    self->placeholder = 0;
  }
  self->current_width = 1;
  self->current_height = 1;
  self->video_output = NULL;
  G_OBJECT_CLASS(texture_gl_parent_class)->dispose(object);
}

static void texture_gl_class_init(TextureGLClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = texture_gl_populate_texture;
  G_OBJECT_CLASS(klass)->dispose = texture_gl_dispose;
}

TextureGL* texture_gl_new(VideoOutput* video_output) {
  TextureGL* self = TEXTURE_GL(g_object_new(texture_gl_get_type(), NULL));
  self->video_output = video_output;
  return self;
}

/* Raster thread, Flutter's context current: called for every composite of
   the Texture widget after a frame was announced. Nothing here waits on mpv
   or on the GPU. */
gboolean texture_gl_populate_texture(FlTextureGL* texture,
                                     guint32* target,
                                     guint32* name,
                                     guint32* width,
                                     guint32* height,
                                     GError** error) {
  TextureGL* self = TEXTURE_GL(texture);
  VideoFrame frame;
  *target = GL_TEXTURE_2D;
  if (self->video_output != NULL) {
    video_output_share_context(self->video_output);
  }
  if (self->video_output != NULL &&
      video_output_take_frame(self->video_output, &frame)) {
    if (self->current_width != frame.width ||
        self->current_height != frame.height) {
      self->current_width = frame.width;
      self->current_height = frame.height;
      video_output_notify_texture_update(self->video_output, frame.width,
                                         frame.height);
    }
    *name = frame.texture;
    *width = self->current_width;
    *height = self->current_height;
    return TRUE;
  }
  if (self->placeholder == 0) {
    glGenTextures(1, &self->placeholder);
    glBindTexture(GL_TEXTURE_2D, self->placeholder);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                 NULL);
    glBindTexture(GL_TEXTURE_2D, 0);
  }
  *name = self->placeholder;
  *width = 1;
  *height = 1;
  return TRUE;
}
