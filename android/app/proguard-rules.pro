# JNI registers whole native tables and looks up callbacks by name; the AAR has no keep rules.
-keep class com.antonkarpenko.ffmpegkit.AbiDetect {
    native <methods>;
}

-keep class com.antonkarpenko.ffmpegkit.FFmpegKitConfig {
    native <methods>;
    private static void log(long, int, byte[]);
    private static void statistics(long, int, float, float, long, double, double, double);
    private static int safOpen(int);
    private static int safClose(int);
}
