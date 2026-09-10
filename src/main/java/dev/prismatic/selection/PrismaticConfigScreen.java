package dev.prismatic.selection;

import net.minecraft.client.gui.components.AbstractSliderButton;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

import java.util.Locale;

public final class PrismaticConfigScreen extends Screen {
    private final Screen parent;

    public PrismaticConfigScreen(Screen parent) {
        super(Component.literal("Prismatic Selection+"));
        this.parent = parent;
    }

    public static Screen create(Screen parent) { return new PrismaticConfigScreen(parent); }

    @Override
    protected void init() {
        int cx = this.width / 2;
        int left = cx - 155;
        int right = cx + 5;
        int y = 50;
        int w = 150;
        int h = 20;
        int gap = 24;

        addRenderableWidget(new Button.Builder(enabledText(), b -> {
            PrismaticConfig.enabled = !PrismaticConfig.enabled;
            b.setMessage(enabledText());
        }).bounds(left, y, w, h).build());

        addRenderableWidget(new Button.Builder(styleText(), b -> {
            PrismaticConfig.Style[] values = PrismaticConfig.Style.values();
            PrismaticConfig.style = values[(PrismaticConfig.style.ordinal() + 1) % values.length];
            b.setMessage(styleText());
        }).bounds(right, y, w, h).build());
        y += gap;

        addRenderableWidget(new ConfigSlider(left, y, w, h, "Rainbow Speed", 0.5, 12.0, 0.25,
                () -> PrismaticConfig.rainbowSpeed, v -> PrismaticConfig.rainbowSpeed = v));
        addRenderableWidget(new ConfigSlider(right, y, w, h, "Saturation", 0.0, 1.0, 0.05,
                () -> PrismaticConfig.saturation, v -> PrismaticConfig.saturation = v));
        y += gap;

        addRenderableWidget(new ConfigSlider(left, y, w, h, "Brightness", 0.25, 1.0, 0.05,
                () -> PrismaticConfig.brightness, v -> PrismaticConfig.brightness = v));
        addRenderableWidget(new ConfigSlider(right, y, w, h, "Opacity", 0.10, 1.0, 0.05,
                () -> PrismaticConfig.opacity, v -> PrismaticConfig.opacity = v));
        y += gap;

        addRenderableWidget(new ConfigSlider(left, y, w, h, "Outline Thickness", 0.50, 4.0, 0.05,
                () -> PrismaticConfig.lineWidthMultiplier, v -> PrismaticConfig.lineWidthMultiplier = v));

        addRenderableWidget(new Button.Builder(smoothText(), b -> {
            PrismaticConfig.smoothTransitions = !PrismaticConfig.smoothTransitions;
            b.setMessage(smoothText());
        }).bounds(right, y, w, h).build());
        y += gap;

        addRenderableWidget(new ConfigSlider(left, y, 310, h, "Transition Speed", 2.0, 40.0, 1.0,
                () -> PrismaticConfig.transitionSpeed, v -> PrismaticConfig.transitionSpeed = v));

        int bottomY = Math.min(this.height - 32, y + 42);
        addRenderableWidget(new Button.Builder(Component.literal("Reset Defaults"), b -> {
            PrismaticConfig.resetDefaults();
            rebuildWidgets();
        }).bounds(cx - 155, bottomY, 100, 20).build());

        addRenderableWidget(new Button.Builder(Component.literal("Save & Done"), b -> {
            PrismaticConfig.save();
            onClose();
        }).bounds(cx + 55, bottomY, 100, 20).build());
    }

    private Component enabledText() { return Component.literal("Enabled: " + (PrismaticConfig.enabled ? "ON" : "OFF")); }

    private Component styleText() {
        String s = PrismaticConfig.style.name().toLowerCase(Locale.ROOT);
        s = Character.toUpperCase(s.charAt(0)) + s.substring(1);
        return Component.literal("Style: " + s);
    }

    private Component smoothText() { return Component.literal("Smooth Transitions: " + (PrismaticConfig.smoothTransitions ? "ON" : "OFF")); }

    @Override
    public void onClose() {
        PrismaticConfig.save();
        if (this.minecraft != null) this.minecraft.gui.setScreen(parent);
    }

    private interface DoubleGetter { double get(); }
    private interface DoubleSetter { void set(double value); }

    private static final class ConfigSlider extends AbstractSliderButton {
        private final String label;
        private final double min;
        private final double max;
        private final double step;
        private final DoubleSetter setter;

        ConfigSlider(int x, int y, int width, int height, String label,
                     double min, double max, double step, DoubleGetter getter, DoubleSetter setter) {
            super(x, y, width, height, Component.empty(), normalize(getter.get(), min, max));
            this.label = label;
            this.min = min;
            this.max = max;
            this.step = step;
            this.setter = setter;
            applyValue();
            updateMessage();
        }

        private static double normalize(double v, double min, double max) {
            if (max <= min) return 0.0;
            return Math.max(0.0, Math.min(1.0, (v - min) / (max - min)));
        }

        private double currentValue() {
            double raw = min + this.value * (max - min);
            double stepped = Math.round(raw / step) * step;
            return Math.max(min, Math.min(max, stepped));
        }

        @Override
        protected void updateMessage() {
            if (label == null) return;
            double v = currentValue();
            String text = step >= 1.0 ? String.format(Locale.ROOT, "%.0f", v) : String.format(Locale.ROOT, "%.2f", v);
            setMessage(Component.literal(label + ": " + text));
        }

        @Override
        protected void applyValue() { if (setter != null) setter.set(currentValue()); }
    }
}
