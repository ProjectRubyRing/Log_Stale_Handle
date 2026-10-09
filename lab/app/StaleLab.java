import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.LocalTime;
import java.time.format.DateTimeFormatter;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

/**
 * Stale file handle の検証用プログラム（ECS タスクの中の JBoss アプリの代わり）。
 *
 *   java StaleLab raw <path>   FileOutputStream(path, append=true) で 1 行ずつ書く。
 *                              Log4j2 の FileManager と同じ開き方（O_APPEND）で、例外をそのまま表示する。
 *   java StaleLab log4j        Log4j2 の Logger で 1 行ずつ書く（設定は -Dlog4j2.configurationFile）。
 *
 * 環境変数: TASK_NAME（行に入れる名前）, INTERVAL_MS（書く間隔）, DURATION_SEC（動かす秒数）
 * 各行には "task=<名前> seq=<連番>" を入れる。あとで連番の抜けを数えて、消えた行を数えられる。
 */
public class StaleLab {
    private static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("HH:mm:ss.SSS");

    static String ts() {
        return LocalTime.now().format(TS);
    }

    static long envLong(String name, long def) {
        String v = System.getenv(name);
        return (v == null || v.isEmpty()) ? def : Long.parseLong(v);
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: StaleLab raw <path> | StaleLab log4j");
            System.exit(2);
        }
        String task = System.getenv().getOrDefault("TASK_NAME", "task");
        long interval = envLong("INTERVAL_MS", 500);
        long duration = envLong("DURATION_SEC", 60);
        if ("raw".equals(args[0])) {
            raw(args[1], task, interval, duration);
        } else {
            log4j(task, interval, duration);
        }
    }

    static void raw(String path, String task, long interval, long duration) throws Exception {
        FileOutputStream out = new FileOutputStream(path, true);
        System.out.println(ts() + " [" + task + "] opened " + path + " (append)");
        long end = System.currentTimeMillis() + duration * 1000;
        long seq = 0;
        long errors = 0;
        String firstError = null;
        while (System.currentTimeMillis() < end) {
            seq++;
            byte[] line = (ts() + " task=" + task + " seq=" + seq + "\n").getBytes(StandardCharsets.UTF_8);
            try {
                out.write(line);
            } catch (IOException e) {
                errors++;
                if (errors == 1) {
                    firstError = ts() + " seq=" + seq;
                    System.out.println(ts() + " [" + task + "] write FAILED at seq=" + seq);
                    e.printStackTrace(System.out);
                } else if (errors % 20 == 0) {
                    System.out.println(ts() + " [" + task + "] still failing: errors=" + errors + " (" + e.getMessage() + ")");
                }
            }
            Thread.sleep(interval);
        }
        try {
            out.close();
            System.out.println(ts() + " [" + task + "] close OK");
        } catch (IOException e) {
            System.out.println(ts() + " [" + task + "] close FAILED: " + e);
        }
        System.out.println(ts() + " [" + task + "] SUMMARY writes=" + seq + " errors=" + errors
                + " firstError=" + (firstError == null ? "-" : firstError));
    }

    static void log4j(String task, long interval, long duration) throws Exception {
        Logger log = LogManager.getLogger("lab");
        System.out.println(ts() + " [" + task + "] log4j start");
        long end = System.currentTimeMillis() + duration * 1000;
        long seq = 0;
        while (System.currentTimeMillis() < end) {
            seq++;
            log.info("task={} seq={}", task, seq);
            Thread.sleep(interval);
        }
        System.out.println(ts() + " [" + task + "] SUMMARY events=" + seq);
        LogManager.shutdown();
    }
}
