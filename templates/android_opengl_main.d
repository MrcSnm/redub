module android_app;

import core.stdc.math : sinf;
import core.stdc.stdio : snprintf;
import std.string : toStringz;

extern(C) int __android_log_write(int priority, const(char)* tag, const(char)* text);
extern(C) void glViewport(int x, int y, int width, int height);
extern(C) void glClearColor(float r, float g, float b, float a);
extern(C) void glClear(uint mask);

private enum uint GL_COLOR_BUFFER_BIT = 0x00004000;
private float elapsed;

extern(C) void redub_android_init(int width, int height)
{
    glViewport(0, 0, width, height);
}

extern(C) void redub_android_draw()
{
    elapsed += 0.016f;
    float red = 0.5f + 0.5f * sinf(elapsed);
    glClearColor(red, 0.2f, 0.4f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}

extern(C) void redub_android_touch(int action, float x, float y)
{
    char[128] buffer;
    snprintf(buffer.ptr, buffer.length, "touch action=%d x=%.1f y=%.1f", action, x, y);
    __android_log_write(4, "redub".toStringz, buffer.ptr);
}

extern(C) void redub_android_destroy()
{
}
