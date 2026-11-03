package com.example.fluent_qwen_probe;

import android.app.*;
import android.content.Context;
import android.os.*;
import io.flutter.plugin.common.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** Explicit maintainer instrumentation: exercises the installed private bridge
 * and service, without a Flutter engine, network, or changes to user settings. */
public final class NativeProbe extends Instrumentation {
  private Bundle args;
  private Context app;
  private Object bridge;
  private final Wire wire = new Wire();
  private final List<Object> records = Collections.synchronizedList(new ArrayList<>());
  private String owner;
  private static final class Wire implements BinaryMessenger {
    BinaryMessageHandler handler;
    public void send(String channel, ByteBuffer message) { throw new UnsupportedOperationException(); }
    public void send(String channel, ByteBuffer message, BinaryReply callback) { throw new UnsupportedOperationException(); }
    public void setMessageHandler(String channel, BinaryMessageHandler value) { handler = value; }
  }
  @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); args = arguments; start(); }
  @SuppressWarnings("unchecked")
  private Map<String,Object> call(String method, Map<String,Object> value) throws Exception {
    CountDownLatch done = new CountDownLatch(1);
    Object[] response = new Object[1];
    Throwable[] error = new Throwable[1];
    long start = SystemClock.elapsedRealtime();
    runOnMainSync(() -> {
      try {
        ByteBuffer input = StandardMethodCodec.INSTANCE.encodeMethodCall(new MethodCall(method, value));
        input.flip();
        wire.handler.onMessage(input, encoded -> {
          try {
            if (encoded == null) throw new IllegalStateException("Missing method reply");
            encoded.flip(); response[0] = StandardMethodCodec.INSTANCE.decodeEnvelope(encoded);
          } catch (Throwable e) { error[0] = e; }
          finally { done.countDown(); }
        });
      } catch (Throwable e) { error[0]=e; done.countDown(); }
    });
    if (!done.await(720,TimeUnit.SECONDS)) throw new TimeoutException(method);
    if (error[0]!=null) throw new RuntimeException(error[0]);
    Map<String,Object> result = response[0] instanceof Map ? (Map<String,Object>) response[0] : new HashMap<>();
    Map<String,Object> entry = new LinkedHashMap<>();
    entry.put("method",method); entry.put("operation",value.get("op"));
    entry.put("seconds",(SystemClock.elapsedRealtime()-start)/1000.0); entry.put("response",result);
    ActivityManager.MemoryInfo memory = new ActivityManager.MemoryInfo();
    ((ActivityManager)app.getSystemService(Context.ACTIVITY_SERVICE)).getMemoryInfo(memory);
    entry.put("availableBytes",memory.availMem); entry.put("totalBytes",memory.totalMem);
    if (result.get("workerPid") instanceof Number) {
      int pid=((Number)result.get("workerPid")).intValue();
      try {
        for(String line:Files.readAllLines(new File("/proc/"+pid+"/status").toPath())) {
          if(line.startsWith("VmRSS:")||line.startsWith("VmHWM:")||line.startsWith("VmSize:")) {
            entry.put(line.split(":")[0]+"KiB",Long.parseLong(line.replaceAll("[^0-9]","")));
          }
        }
      } catch(Exception ignored) {}
    }
    records.add(entry);
    return result;
  }
  private Map<String,Object> request(Object... pairs) throws Exception {
    Map<String,Object> value=new LinkedHashMap<>(); value.put("owner",owner);
    for(int i=0;i<pairs.length;i+=2)value.put((String)pairs[i],pairs[i+1]);
    return call("request",value);
  }
  @Override public void onStart() {
    app=getTargetContext();
    File report=new File(app.getFilesDir(),"qwen-native-probe/report.json");
    Map<String,Object> result=new LinkedHashMap<>();
    try {
      runOnMainSync(() -> {
        try {
          Class<?> type=app.getClassLoader().loadClass("com.example.video_player_app.QwenAsrBridge");
          bridge=type.getConstructor(Context.class,BinaryMessenger.class).newInstance(app,wire);
        } catch(Exception e) { throw new RuntimeException(e); }
      });
      result.put("device",Build.MODEL); result.put("sdk",Build.VERSION.SDK_INT);
      result.put("cache",app.getCacheDir().getCanonicalPath());
      result.put("codeCache",app.getCodeCacheDir().getCanonicalPath());
      String kind=args.getString("kind","asr");
      File audio=new File(app.getCacheDir(),"qwen-native-probe/input.f32");
      File codeAudio=new File(app.getCodeCacheDir(),"qwen-native-probe/input.f32");
      codeAudio.getParentFile().mkdirs();
      try(InputStream in=new FileInputStream(audio);OutputStream out=new FileOutputStream(codeAudio)) {
        byte[] block=new byte[65536];int n;while((n=in.read(block))>0)out.write(block,0,n);
      }
      owner="native-probe-"+System.nanoTime();
      request("op","open");
      Map<String,Object> loaded=request("op","load","kind",kind,"model",args.getString("model"),
        "threads",Integer.parseInt(args.getString("threads","4")),"backend",args.getString("backend","cpu"),"language","ja");
      if(!Boolean.TRUE.equals(loaded.get("ok")))throw new IllegalStateException("Model did not load");
      if (args.getString("stallGpu", "false").equals("true")) {
        if (args.getString("backend", "cpu").equals("cpu")) {
          throw new IllegalArgumentException("GPU stall check requires a GPU owner");
        }
        // Explicit maintainer fault injection into this same-UID private
        // worker only. The app's production deadline must terminate it and
        // permit a fresh CPU owner; no device or app-wide process is paused.
        android.os.Process.sendSignal(((Number)loaded.get("workerPid")).intValue(), 19);
      }
      String operation=kind.equals("aligner")?"align":kind.equals("lid")?"identify":"decode";
      Map<String,Object> fields=new LinkedHashMap<>();
      if (args.getString("cancel", "false").equals("true")) {
        FutureTask<Map<String,Object>> decoding = new FutureTask<>(() ->
            request("op", "decode", "path", codeAudio.getPath()));
        new Thread(decoding, "QwenProbeDecode").start();
        Thread.sleep(250);
        call("close", Collections.singletonMap("owner", owner));
        Map<String,Object> cancelled = decoding.get(15, TimeUnit.SECONDS);
        result.put("cancelledResult", cancelled);
        if (Boolean.TRUE.equals(cancelled.get("ok"))) {
          throw new IllegalStateException("Cancelled inference was accepted");
        }
        owner = "native-recovery-" + System.nanoTime();
        request("op", "open");
        request("op", "load", "kind", "asr", "model", args.getString("model"),
            "threads", 4, "backend", "cpu", "language", "ja");
        Map<String,Object> recovered = request("op", "decode", "path", codeAudio.getPath());
        result.put("recoveredResult", recovered);
        if (!Boolean.TRUE.equals(recovered.get("ok"))) {
          throw new IllegalStateException("Fresh CPU owner did not recover");
        }
        result.put("completed", true);
        return;
      }
      if(kind.equals("aligner")) {
        Map<String,Object> tokens=request("op","tokenize","language","ja","text",args.getString("text","こんにちは。"));
        List<String> words=new ArrayList<>();
        for(Object token:(List<?>)tokens.get("units"))words.add((String)((Map<?,?>)token).get("text"));
        fields.put("words",words);
      }
      for(File input:new File[]{codeAudio,audio}) {
        Map<String,Object> message=new LinkedHashMap<>(fields);
        message.put("owner",owner);message.put("op",operation);message.put("path",input.getPath());
        result.put(input==codeAudio?"codeCacheResult":"cacheResult",call("request",message));
      }
      if (args.getString("backend", "cpu").equals("vulkan")) {
        call("close", Collections.singletonMap("owner", owner));
        owner = "native-driver-recovery-" + System.nanoTime();
        request("op", "open");
        result.put("postCrashCapabilities", request("op", "capabilities"));
        request("op", "load", "kind", "asr", "model", args.getString("model"),
            "threads", 4, "backend", "cpu", "language", "ja");
        result.put("recoveredResult", request("op", "decode", "path", codeAudio.getPath()));
      }
      result.put("completed",true);
    } catch(Throwable error) {
      result.put("exception",error.toString());
    } finally {
      try { if(owner!=null)call("close",Collections.singletonMap("owner",owner)); }catch(Exception ignored){}
      result.put("records",records);
      try { report.getParentFile().mkdirs();Files.write(report.toPath(),new JSONObject(result).toString(2).getBytes("UTF-8")); }
      catch(Exception ignored) {}
      Bundle summary=new Bundle();summary.putString("report",report.getPath());
      summary.putString("completed",String.valueOf(result.get("completed")));
      finish(result.containsKey("exception")?1:-1,summary);
    }
  }
}
