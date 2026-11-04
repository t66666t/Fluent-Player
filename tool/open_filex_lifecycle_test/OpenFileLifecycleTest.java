import com.crazecoder.openfile.OpenFilePlugin;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.StandardMethodCodec;
import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

/** Uses the real plugin and Flutter channel/codec; only the host bindings are fake. */
public final class OpenFileLifecycleTest {
    private static final class Messenger implements BinaryMessenger {
        final Map<String, BinaryMessageHandler> handlers = new HashMap<>();
        int registrations;

        @Override public void setMessageHandler(String channel, BinaryMessageHandler handler) {
            if (handler == null) handlers.remove(channel);
            else {
                handlers.put(channel, handler);
                registrations++;
            }
        }
        @Override public void send(String channel, ByteBuffer message) {
            throw new AssertionError("Unexpected outbound message");
        }
        @Override public void send(String channel, ByteBuffer message, BinaryReply callback) {
            throw new AssertionError("Unexpected outbound message");
        }

        void dispatch(String phase) {
            BinaryMessageHandler handler = handlers.get("open_file");
            check(handler != null, phase + ": open_file channel is absent");
            ByteBuffer message = StandardMethodCodec.INSTANCE.encodeMethodCall(
                    new MethodCall("lifecycle_probe_unknown_method", null));
            message.flip();
            int[] replies = {0};
            handler.onMessage(message, response -> {
                replies[0]++;
                check(response == null, "Real plugin must reply notImplemented to probe");
            });
            check(replies[0] == 1, phase + ": real plugin did not handle method call");
        }
    }

    private static ActivityPluginBinding activityBinding() {
        return (ActivityPluginBinding) Proxy.newProxyInstance(
                ActivityPluginBinding.class.getClassLoader(),
                new Class<?>[] {ActivityPluginBinding.class},
                (proxy, method, args) -> null);
    }

    private static FlutterPluginBinding engineBinding(Messenger messenger) {
        return new FlutterPluginBinding(null, null, messenger, null, null, null, null);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void initialAttachment() {
        OpenFilePlugin plugin = new OpenFilePlugin();
        Messenger messenger = new Messenger();
        plugin.onAttachedToEngine(engineBinding(messenger));
        plugin.onAttachedToActivity(activityBinding());
        messenger.dispatch("initial attach");
        check(messenger.registrations == 1, "Initial activity attach must not replace channel");
    }

    private static void configurationReattachment() {
        OpenFilePlugin plugin = new OpenFilePlugin();
        Messenger messenger = new Messenger();
        plugin.onAttachedToEngine(engineBinding(messenger));
        plugin.onAttachedToActivity(activityBinding());
        for (int index = 0; index < 5; index++) {
            plugin.onDetachedFromActivityForConfigChanges();
            check(!messenger.handlers.containsKey("open_file"), "Config detach must unregister");
            plugin.onReattachedToActivityForConfigChanges(activityBinding());
            messenger.dispatch("config reattach " + index);
        }
        check(messenger.registrations == 6, "One channel registration per reattach");
    }

    private static void cachedEngineReattachment() {
        OpenFilePlugin plugin = new OpenFilePlugin();
        Messenger messenger = new Messenger();
        plugin.onAttachedToEngine(engineBinding(messenger));
        plugin.onAttachedToActivity(activityBinding());
        plugin.onDetachedFromActivity();
        check(!messenger.handlers.containsKey("open_file"), "Activity detach must unregister");
        plugin.onAttachedToActivity(activityBinding());
        messenger.dispatch("cached-engine new activity");
    }

    private static void engineReplacement() {
        OpenFilePlugin plugin = new OpenFilePlugin();
        Messenger old = new Messenger();
        FlutterPluginBinding oldBinding = engineBinding(old);
        plugin.onAttachedToEngine(oldBinding);
        plugin.onAttachedToActivity(activityBinding());
        plugin.onDetachedFromActivity();
        plugin.onDetachedFromEngine(oldBinding);
        plugin.onAttachedToActivity(activityBinding());
        check(old.handlers.isEmpty(), "Activity must not revive detached engine's channel");
        Messenger replacement = new Messenger();
        FlutterPluginBinding replacementBinding = engineBinding(replacement);
        plugin.onAttachedToEngine(replacementBinding);
        replacement.dispatch("replacement engine");
        plugin.onDetachedFromEngine(replacementBinding);
        check(replacement.handlers.isEmpty(), "Engine detach must unregister");
        check(old.handlers.isEmpty(), "Old engine must stay disconnected");
    }

    public static void main(String[] args) {
        Runnable[] tests = {OpenFileLifecycleTest::initialAttachment,
                OpenFileLifecycleTest::configurationReattachment,
                OpenFileLifecycleTest::cachedEngineReattachment,
                OpenFileLifecycleTest::engineReplacement};
        int failures = 0;
        for (int index = 0; index < tests.length; index++) {
            try {
                tests[index].run();
                System.out.println("PASS case " + (index + 1));
            } catch (Throwable failure) {
                failures++;
                System.out.println("FAIL case " + (index + 1) + ": " + failure);
            }
        }
        System.out.println("RESULT " + (tests.length - failures) + "/" + tests.length + " pass");
        if (failures > 0) System.exit(1);
    }
}
