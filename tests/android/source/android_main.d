module app;

import core.thread : Thread;
import core.time : seconds;
import std.string : toStringz;

extern(C) int __android_log_write(int priority, const(char)* tag, const(char)* text);

extern(C) void android_d_main(void* app)
{
    __android_log_write(4, "redub".toStringz, "hello from D on Android".toStringz);
    Thread.sleep(5.seconds);
}
