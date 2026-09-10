package dev.prismatic.selection;

import com.mojang.blaze3d.platform.InputConstants;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.keymapping.v1.KeyMappingHelper;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.resources.Identifier;
import org.lwjgl.glfw.GLFW;

public final class PrismaticSelectionClient implements ClientModInitializer {
    private static KeyMapping openConfig;

    @Override
    public void onInitializeClient() {
        PrismaticConfig.load();

        KeyMapping.Category category = KeyMapping.Category.register(
                Identifier.fromNamespaceAndPath("prismatic-selection-plus", "controls"));
        openConfig = KeyMappingHelper.registerKeyMapping(new KeyMapping(
                "key.prismatic-selection-plus.open_config",
                InputConstants.Type.KEYSYM,
                GLFW.GLFW_KEY_P,
                category));

        ClientTickEvents.END_CLIENT_TICK.register(PrismaticSelectionClient::onEndTick);
        System.out.println("[Prismatic Selection+] 1.0.0 initialized. Press P to open settings.");
    }

    private static void onEndTick(Minecraft client) {
        while (openConfig.consumeClick()) {
            client.gui.setScreen(PrismaticConfigScreen.create(client.gui.screen()));
        }
    }
}
