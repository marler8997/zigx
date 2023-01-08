#include <errno.h>
#include <stdio.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define logf(fmt, ...) fprintf(stderr, fmt "\n", ##__VA_ARGS__); fflush(stderr)
#define errorf(fmt, ...) fprintf(stderr, "error: " fmt "\n", ##__VA_ARGS__); fflush(stderr)

static void on_error(void *ctx, const char *msg)
{
    errorf("error: %s\n", msg);
}

int main(int argc, char *argv[])
{
#ifdef ZIGX_EXTENSIONS
    ZigXSetErrorHandler(on_error, NULL);
#endif

    logf("Calling XOpenDisplay...");
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        errorf("XOpenDisplay failed");
        return 1;
    }

    logf("Proto version %d.%d\n", ProtocolVersion(display), ProtocolRevision(display));

    int screen = DefaultScreen(display);
    logf("default screen is %d\n", screen);

    unsigned long black = BlackPixel(display, screen);
    unsigned long white = WhitePixel(display, screen);
    logf("black=0x%lx white=0x%lx", black, white);

    XSizeHints size_hints;
    size_hints.x = 200;
    size_hints.y = 300;
    size_hints.width = 350;
    size_hints.height = 250;
    size_hints.flags = PPosition|PSize;
    Window window = XCreateSimpleWindow(
        display,
        DefaultRootWindow(display),
        size_hints.x, size_hints.y,
        size_hints.width, size_hints.height,
        5, // border width
        black, // border color
        white); // background
    /*
    XSetStandardProperties(
        display,
        window,
        "Hello X11", // window_name
        "Hello X11", // icon_name
        None, // icon_pixmap
        argv,
        argc,
        &size_hints);
    */

    GC gc = XCreateGC(display, window, 0, 0);

    // TODO: XSetBackground(display, gc, white);
    // TODO: XSetForeground(display, gc, black);
    XSelectInput(display, window, ButtonPressMask|KeyPressMask|ExposureMask);

    XMapRaised(display, window);

    while (1) {
        logf("getting next event...");
        XEvent event;
        XNextEvent(display, &event);
        switch (event.type) {
        case Expose:
            logf("TODO: handle expose event!");
            break;
        case MappingNotify:
            logf("TODO: handle mapping notify!");
            break;
        case ButtonPress:
            logf("TODO: button press!");
            break;
        case KeyPress:
            logf("TODO: handle key press!");
            break;
        default:
            error("unknown even type %d", event.type);
            exit(1);
        }
    }

    // TODO: XFreeGC(display, gc);
    // TODO: XDestroyWindow(display, window);

    {
        int result = XCloseDisplay(display);
        if (result != 0) {
            errorf("XCloseDisplay failed with %d, errno=%d", result, errno);
            return 1;
        }
    }

    return 0;
}
