
struct android_app;

extern int rt_init(void);
extern int rt_term(void);
extern void android_d_main(void* app);

void android_main(struct android_app* app)
{
    rt_init();
    android_d_main(app);
    rt_term();
}