package dev.prismatic.selection;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class PrismaticConfig {
    public enum Style { RAINBOW, SOLID, PULSE }

    private static final Path PATH = Path.of("config", "prismatic-selection-plus.json");

    public static boolean enabled = true;
    public static Style style = Style.RAINBOW;
    public static double rainbowSpeed = 5.0;
    public static double saturation = 0.88;
    public static double brightness = 1.0;
    public static double opacity = 1.0;
    public static double lineWidthMultiplier = 1.35;
    public static String solidColor = "#FFFFFF";
    public static boolean smoothTransitions = false;
    public static double transitionSpeed = 18.0;

    private PrismaticConfig() {}

    public static void load() {
        try {
            Files.createDirectories(PATH.getParent());
            if (!Files.exists(PATH)) { save(); return; }
            String s = Files.readString(PATH, StandardCharsets.UTF_8);
            enabled = bool(s, "enabled", enabled);
            String styleName = str(s, "style", style.name());
            try { style = Style.valueOf(styleName.toUpperCase(Locale.ROOT)); } catch (IllegalArgumentException ignored) {}
            rainbowSpeed = number(s, "rainbowSpeed", rainbowSpeed);
            saturation = number(s, "saturation", saturation);
            brightness = number(s, "brightness", brightness);
            opacity = number(s, "opacity", opacity);
            lineWidthMultiplier = number(s, "lineWidthMultiplier", lineWidthMultiplier);
            solidColor = str(s, "solidColor", solidColor);
            smoothTransitions = bool(s, "smoothTransitions", smoothTransitions);
            transitionSpeed = number(s, "transitionSpeed", transitionSpeed);
        } catch (IOException e) {
            System.err.println("[Prismatic Selection+] Config load failed: " + e.getMessage());
        }
    }

    public static void save() {
        try {
            Files.createDirectories(PATH.getParent());
            String json = String.format(Locale.ROOT, """
{
  \"enabled\": %s,
  \"style\": \"%s\",
  \"rainbowSpeed\": %.2f,
  \"saturation\": %.2f,
  \"brightness\": %.2f,
  \"opacity\": %.2f,
  \"lineWidthMultiplier\": %.2f,
  \"solidColor\": \"%s\",
  \"smoothTransitions\": %s,
  \"transitionSpeed\": %.2f
}
""", enabled, style.name(), rainbowSpeed, saturation, brightness, opacity,
                    lineWidthMultiplier, solidColor.replace("\"", ""), smoothTransitions, transitionSpeed);
            Files.writeString(PATH, json, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE);
        } catch (IOException e) {
            System.err.println("[Prismatic Selection+] Config save failed: " + e.getMessage());
        }
    }

    public static void resetDefaults() {
        enabled = true; style = Style.RAINBOW; rainbowSpeed = 5.0; saturation = 0.88;
        brightness = 1.0; opacity = 1.0; lineWidthMultiplier = 1.35; solidColor = "#FFFFFF";
        smoothTransitions = false; transitionSpeed = 18.0;
    }

    private static boolean bool(String s, String key, boolean fallback) {
        Matcher m = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(true|false)", Pattern.CASE_INSENSITIVE).matcher(s);
        return m.find() ? Boolean.parseBoolean(m.group(1)) : fallback;
    }

    private static double number(String s, String key, double fallback) {
        Matcher m = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)").matcher(s);
        if (!m.find()) return fallback;
        try { return Double.parseDouble(m.group(1)); } catch (NumberFormatException e) { return fallback; }
    }

    private static String str(String s, String key, String fallback) {
        Matcher m = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"").matcher(s);
        return m.find() ? m.group(1) : fallback;
    }
}
