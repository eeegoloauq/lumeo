// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_H_
#define VIDEO_OUTPUT_H_

#include <flutter_linux/flutter_linux.h>
#include <epoxy/egl.h>

#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"

typedef struct _VideoOutputConfiguration {
  gint64 width;
  gint64 height;
  bool enable_hardware_acceleration;

  _VideoOutputConfiguration(gint64 width = NULL,
                            gint64 height = NULL,
                            bool enable_hardware_acceleration = true)
      : width(width),
        height(height),
        enable_hardware_acceleration(enable_hardware_acceleration) {}
} VideoOutputConfiguration;

// Callback invoked when the texture ID updates i.e. video dimensions changes.
typedef void (*TextureUpdateCallback)(gint64 id,
                                      gint64 width,
                                      gint64 height,
                                      gpointer context);

#define VIDEO_OUTPUT_TYPE (video_output_get_type())

G_DECLARE_FINAL_TYPE(VideoOutput,
                     video_output,
                     VIDEO_OUTPUT,
                     VIDEO_OUTPUT,
                     GObject)

#define VIDEO_OUTPUT(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), video_output_get_type(), VideoOutput))

/**
 * @brief Creates a new |VideoOutput| instance for given |handle|.
 *
 * @param texture_registrar |FlTextureRegistrar| reference.
 * @param handle |mpv_handle| reference casted to gint64.
 * @param width Preferred width of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 * @param height Preferred height of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 * @param enable_hardware_acceleration Whether to enable hardware acceleration.
 * @return VideoOutput*
 */
VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration);

/**
 * @brief Sets the callback invoked when the texture ID updates i.e. video
 * dimensions changes.
 *
 * @param self |VideoOutput| reference.
 * @param texture_update_callback Callback.
 * @param texture_update_callback_context Callback context.
 */
void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context);

/**
 * @brief Sets the required video output size. This forces |VideoOutput| to
 * resize the internal OpenGL surface / texture.
 *
 * @param texture_registrar |FlTextureRegistrar| reference.
 * @param width Preferred width of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 * @param height Preferred height of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 */
void video_output_set_size(VideoOutput* self, gint64 width, gint64 height);

/* Lumeo patch. A finished frame, as the raster thread takes it from the
   render thread: a texture in Flutter's share group, the buffer mpv drew
   into, and its size. */
typedef struct _VideoFrame {
  guint32 texture;
  gint64 width;
  gint64 height;
} VideoFrame;

/**
 * @brief Makes mpv's EGL context in the share group of the one current, and
 * lets the render thread start. Called by the texture's populate — Flutter's
 * raster thread, Flutter's render context current — and does nothing after
 * the first time.
 */
void video_output_share_context(VideoOutput* self);

/**
 * @brief Hands the raster thread the latest frame the render thread has
 * finished. Must be called with Flutter's EGL context current: the buffer
 * shown before this one gets a fence in it, which the render thread waits on
 * before drawing into that buffer again.
 *
 * @return FALSE while no frame has been rendered yet.
 */
gboolean video_output_take_frame(VideoOutput* self, VideoFrame* frame);

mpv_render_context* video_output_get_render_context(VideoOutput* self);

GdkGLContext* video_output_get_gdk_gl_context(VideoOutput* self);

EGLDisplay video_output_get_egl_display(VideoOutput* self);

EGLContext video_output_get_egl_context(VideoOutput* self);

guint8* video_output_get_pixel_buffer(VideoOutput* self);

gint64 video_output_get_width(VideoOutput* self);

gint64 video_output_get_height(VideoOutput* self);

gint64 video_output_get_texture_id(VideoOutput* self);

/* Lumeo patch: announces the size the texture actually has, which on the
   H/W path is the frame's, not necessarily |width|x|height| yet. */
void video_output_notify_texture_update(VideoOutput* self,
                                        gint64 width,
                                        gint64 height);

#endif  // VIDEO_OUTPUT_H_