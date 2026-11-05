#include "android_native_app_glue.h"
#include <android/input.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

extern int rt_init(void);
extern int rt_term(void);
extern void redub_android_init(int width, int height);
extern void redub_android_destroy(void);
extern void redub_android_draw(void);
extern void redub_android_touch(int action, float x, float y);

struct redub_engine
{
    struct android_app* app;
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
    int32_t width;
    int32_t height;
    int animating;
};

static struct redub_engine engine;

static int engine_init_display(struct redub_engine* state)
{
    const EGLint attribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_BLUE_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_RED_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE
    };
    EGLint numConfigs, format, w, h;
    EGLConfig config;
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if(display == EGL_NO_DISPLAY)
        return -1;
    if(!eglInitialize(display, NULL, NULL))
        return -1;
    if(!eglChooseConfig(display, attribs, &config, 1, &numConfigs) || numConfigs < 1)
        return -1;
    if(!eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format))
        return -1;
    ANativeWindow_setBuffersGeometry(state->app->window, 0, 0, format);
    EGLSurface surface = eglCreateWindowSurface(display, config, state->app->window, NULL);
    if(surface == EGL_NO_SURFACE)
        return -1;
    EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
    if(context == EGL_NO_CONTEXT)
        return -1;
    if(!eglMakeCurrent(display, surface, surface, context))
        return -1;
    eglQuerySurface(display, surface, EGL_WIDTH, &w);
    eglQuerySurface(display, surface, EGL_HEIGHT, &h);
    state->display = display;
    state->context = context;
    state->surface = surface;
    state->width = w;
    state->height = h;
    glViewport(0, 0, w, h);
    redub_android_init(w, h);
    return 0;
}

static void engine_term_display(struct redub_engine* state)
{
    if(state->display != EGL_NO_DISPLAY)
    {
        redub_android_destroy();
        eglMakeCurrent(state->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if(state->context != EGL_NO_CONTEXT)
            eglDestroyContext(state->display, state->context);
        if(state->surface != EGL_NO_SURFACE)
            eglDestroySurface(state->display, state->surface);
        eglTerminate(state->display);
    }
    state->animating = 0;
    state->display = EGL_NO_DISPLAY;
    state->context = EGL_NO_CONTEXT;
    state->surface = EGL_NO_SURFACE;
}

static int32_t engine_handle_input(struct android_app* app, AInputEvent* event)
{
    if(AInputEvent_getType(event) == AINPUT_EVENT_TYPE_MOTION)
    {
        int action = AMotionEvent_getAction(event);
        int masked = action & AMOTION_EVENT_ACTION_MASK;
        size_t index = (action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK)
            >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
        redub_android_touch(masked, AMotionEvent_getX(event, index),
            AMotionEvent_getY(event, index));
        return 1;
    }
    return 0;
}

static void engine_handle_cmd(struct android_app* app, int32_t cmd)
{
    struct redub_engine* state = (struct redub_engine*)app->userData;
    switch(cmd)
    {
        case APP_CMD_INIT_WINDOW:
            if(app->window != NULL && engine_init_display(state) == 0)
                state->animating = 1;
            break;
        case APP_CMD_TERM_WINDOW:
            engine_term_display(state);
            break;
        case APP_CMD_GAINED_FOCUS:
            state->animating = 1;
            break;
        case APP_CMD_LOST_FOCUS:
            state->animating = 0;
            break;
    }
}

static void engine_draw_frame(struct redub_engine* state)
{
    if(state->display == EGL_NO_DISPLAY)
        return;
    redub_android_draw();
    eglSwapBuffers(state->display, state->surface);
}

void android_main(struct android_app* app)
{
    rt_init();
    app->userData = &engine;
    app->onAppCmd = engine_handle_cmd;
    app->onInputEvent = engine_handle_input;
    engine.app = app;
    engine.display = EGL_NO_DISPLAY;
    engine.surface = EGL_NO_SURFACE;
    engine.context = EGL_NO_CONTEXT;
    engine.animating = 0;
    while(1)
    {
        int events;
        struct android_poll_source* source = NULL;
        int result = ALooper_pollOnce(engine.animating ? 0 : -1, NULL,
            &events, (void**)&source);
        if(result == ALOOPER_POLL_ERROR)
            break;
        if(source != NULL)
            source->process(app, source);
        if(app->destroyRequested != 0)
        {
            engine_term_display(&engine);
            rt_term();
            return;
        }
        if(engine.animating)
            engine_draw_frame(&engine);
    }
    engine_term_display(&engine);
    rt_term();
}
