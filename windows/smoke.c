// Loads the library that was just built, starts mpv without video and audio
// output and prints what it reports about itself. The output goes into
// BUILD-INFO.txt. Both the Windows and the macOS build use it.
#include <stdio.h>

#include <mpv/client.h>

int main(void) {
    mpv_handle* mpv = mpv_create();
    if (!mpv) {
        fprintf(stderr, "mpv_create failed\n");
        return 1;
    }
    mpv_set_option_string(mpv, "config", "no");
    mpv_set_option_string(mpv, "terminal", "no");
    mpv_set_option_string(mpv, "vo", "null");
    mpv_set_option_string(mpv, "ao", "null");
    mpv_set_option_string(mpv, "idle", "yes");
    int rc = mpv_initialize(mpv);
    if (rc < 0) {
        fprintf(stderr, "mpv_initialize failed: %s\n", mpv_error_string(rc));
        return 2;
    }

    printf("client API: %lu.%lu\n", mpv_client_api_version() >> 16, mpv_client_api_version() & 0xffff);
    const char* props[] = {"mpv-version", "ffmpeg-version", "libass-version", "mpv-configuration", NULL};
    for (int i = 0; props[i]; i++) {
        char* value = mpv_get_property_string(mpv, props[i]);
        printf("%s: %s\n", props[i], value ? value : "(not available)");
        mpv_free(value);
    }

    // Makes mpv ask the system's audio outputs for their devices. The macOS
    // library once crashed here, in code that a start without sound never ran.
    char* devices = mpv_get_property_string(mpv, "audio-device-list");
    if (!devices) {
        fprintf(stderr, "no audio-device-list\n");
        return 3;
    }
    mpv_free(devices);

    mpv_terminate_destroy(mpv);
    return 0;
}
