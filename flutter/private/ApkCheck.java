import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Checks an APK's native libraries against the libraries the build declared.
 *
 * Usage: ApkCheck SPEC APK REPORT LABEL
 *
 * SPEC is UTF-8, one TAB-separated record per line. Blank lines and lines
 * starting with '#' are ignored.
 *
 *   mode    release|debug                  exactly once
 *   abi     ABI                            every ABI the spec covers
 *   expect  ABI BASENAME PATH              lib/ABI/BASENAME required; CRC-32 read from the file
 *   archive ABI PATH                       lib/ABI/*.so of an AAR or library archive; CRC-32 from the archive
 */
public class ApkCheck {
  private static final String LIB = "lib/";

  // An expected library: its CRC-32, and the file or archive that ships it.
  static final class Expected {
    final long crc;
    final String source;
    final boolean fromArchive;

    Expected(long crc, String source, boolean fromArchive) {
      this.crc = crc;
      this.source = source;
      this.fromArchive = fromArchive;
    }
  }

  static final class Spec {
    String mode;
    final Set<String> abis = new TreeSet<>();
    final Map<String, Map<String, Expected>> expect = new TreeMap<>();
    final List<String[]> archives = new ArrayList<>();
  }

  // A failed check. The message is the full line the build prints.
  static final class CheckFailure extends RuntimeException {
    CheckFailure(String message) {
      super(message);
    }
  }

  private static final class Apk {
    final List<ZipEntry> all = new ArrayList<>();
    final Map<String, List<ZipEntry>> byName = new LinkedHashMap<>();

    Apk(ZipFile zip) {
      Enumeration<? extends ZipEntry> it = zip.entries();
      while (it.hasMoreElements()) {
        ZipEntry e = it.nextElement();
        all.add(e);
        byName.computeIfAbsent(e.getName(), k -> new ArrayList<>()).add(e);
      }
    }

    List<ZipEntry> named(String name) {
      return byName.getOrDefault(name, Collections.emptyList());
    }
  }

  public static void main(String[] args) {
    if (args.length != 4) {
      System.err.println("usage: ApkCheck SPEC APK REPORT LABEL");
      System.exit(2);
    }
    try {
      run(args[0], args[1], args[2], args[3]);
    } catch (CheckFailure e) {
      System.err.println(e.getMessage());
      System.exit(1);
    } catch (IOException e) {
      System.err.println(prefix(args[3], e.toString()));
      System.exit(1);
    }
  }

  private static void run(String specPath, String apkPath, String reportPath, String label)
      throws IOException {
    Spec spec = parseSpec(Paths.get(specPath), label);
    List<String> bad = new ArrayList<>();
    List<String> report;
    try (ZipFile zip = new ZipFile(apkPath)) {
      report = check(spec, zip, bad);
    }
    // Every mismatch is reported in one run, so a failure shows the whole difference.
    if (!bad.isEmpty()) {
      List<String> lines = new ArrayList<>();
      for (String m : bad) {
        lines.add(prefix(label, m));
      }
      throw new CheckFailure(String.join("\n", lines));
    }
    Files.write(
        Paths.get(reportPath),
        (String.join("\n", report) + "\n").getBytes(StandardCharsets.UTF_8));
  }

  private static String prefix(String label, String message) {
    return "flutter_apk_check: " + label + ": " + message;
  }

  private static void fail(String label, String message) {
    throw new CheckFailure(prefix(label, message));
  }

  private static Spec parseSpec(Path file, String label) throws IOException {
    Spec s = new Spec();
    List<String> lines = Files.readAllLines(file, StandardCharsets.UTF_8);
    for (int i = 0; i < lines.size(); i++) {
      String line = lines.get(i);
      if (line.trim().isEmpty() || line.startsWith("#")) {
        continue;
      }
      String where = "spec line " + (i + 1);
      String[] f = line.split("\t", -1);
      switch (f[0]) {
        case "mode":
          arity(f, 2, label, where);
          if (s.mode != null) {
            fail(label, where + ": mode given twice");
          }
          if (!f[1].equals("release") && !f[1].equals("debug")) {
            fail(label, where + ": unknown mode " + f[1]);
          }
          s.mode = f[1];
          break;
        case "abi":
          arity(f, 2, label, where);
          s.abis.add(f[1]);
          break;
        case "expect":
          arity(f, 4, label, where);
          putExpected(s.expect, f[1], f[2], new Expected(fileCrc(f[3]), f[3], false), label, where);
          break;
        case "archive":
          arity(f, 3, label, where);
          s.archives.add(new String[] {f[1], f[2]});
          break;
        default:
          fail(label, where + ": unknown record " + f[0]);
      }
    }
    if (s.mode == null) {
      fail(label, "spec has no mode record");
    }
    for (String abi : s.expect.keySet()) {
      requireDeclared(s, abi, label);
    }
    for (String[] a : s.archives) {
      requireDeclared(s, a[0], label);
    }
    addArchives(s, label);
    return s;
  }

  private static void putExpected(
      Map<String, Map<String, Expected>> m,
      String abi,
      String base,
      Expected e,
      String label,
      String where) {
    if (m.computeIfAbsent(abi, k -> new TreeMap<>()).put(base, e) != null) {
      fail(label, where + ": duplicate " + base + " for " + abi);
    }
  }

  // A name is one library. The same file, or the same bytes from two archives, may
  // appear more than once; any other repeat is an error, since the APK would carry
  // one of the two.
  static void addExpected(Spec s, String abi, String base, Expected e, String label) {
    Map<String, Expected> m = s.expect.computeIfAbsent(abi, k -> new TreeMap<>());
    Expected prev = m.get(base);
    if (prev == null) {
      m.put(base, e);
      return;
    }
    String name = LIB + abi + "/" + base;
    if (prev.source.equals(e.source)) {
      return;
    }
    if (prev.fromArchive && e.fromArchive) {
      if (prev.crc != e.crc) {
        fail(label, name + " is in " + prev.source + " and in " + e.source + " with different CRC-32s");
      }
      return;
    }
    fail(label, name + " is in " + prev.source + " and in " + e.source
        + "; a library name must come from one source");
  }

  // Adds each archive's lib/<abi>/ entries with the CRC-32 the archive records.
  private static void addArchives(Spec s, String label) throws IOException {
    for (String[] a : s.archives) {
      String abi = a[0];
      String prefix = LIB + abi + "/";
      try (ZipFile zip = new ZipFile(a[1])) {
        Enumeration<? extends ZipEntry> it = zip.entries();
        while (it.hasMoreElements()) {
          ZipEntry e = it.nextElement();
          if (!e.getName().startsWith(prefix) || e.isDirectory()) {
            continue;
          }
          String base = e.getName().substring(prefix.length());
          if (base.isEmpty() || base.contains("/") || !base.endsWith(".so")) {
            fail(label, a[1] + " holds " + e.getName() + ", not a library directly under " + prefix);
          }
          addExpected(s, abi, base, new Expected(e.getCrc(), a[1], true), label);
        }
      }
    }
  }

  private static void arity(String[] f, int n, String label, String where) {
    if (f.length != n) {
      fail(label, where + ": " + f[0] + " takes " + (n - 1) + " fields");
    }
  }

  private static void requireDeclared(Spec s, String abi, String label) {
    if (!s.abis.contains(abi)) {
      fail(label, "spec record names undeclared ABI " + abi);
    }
  }

  static List<String> check(Spec s, ZipFile zip, List<String> bad) throws IOException {
    Apk apk = new Apk(zip);
    List<String> report = new ArrayList<>();
    report.add("mode " + s.mode);

    for (String name : new TreeSet<>(apk.byName.keySet())) {
      if (!name.startsWith(LIB)) {
        continue;
      }
      String[] parts = name.split("/", -1);
      if (parts.length != 3 || parts[1].isEmpty() || parts[2].isEmpty()) {
        bad.add("unexpected native entry " + name);
      } else if (!s.abis.contains(parts[1])) {
        bad.add("unexpected ABI " + parts[1] + " in " + name);
      }
      int n = apk.named(name).size();
      if (n > 1) {
        bad.add(name + " occurs " + n + " times");
      }
    }

    int checked = 0;
    for (String abi : s.abis) {
      Map<String, Expected> expected = s.expect.getOrDefault(abi, Collections.emptyMap());
      String prefix = LIB + abi + "/";
      Set<String> present = namesUnder(apk, prefix);
      for (String base : expected.keySet()) {
        if (!present.contains(base)) {
          bad.add("missing " + prefix + base);
        }
      }
      for (String base : present) {
        if (!expected.containsKey(base)) {
          bad.add(prefix + base + " is not declared by the native inputs");
        }
      }
      // Stored libraries load from the APK without extraction, so each must be stored.
      List<String> deflated = new ArrayList<>();
      for (String base : present) {
        List<ZipEntry> found = apk.named(prefix + base);
        if (base.endsWith(".so") && found.size() == 1
            && found.get(0).getMethod() != ZipEntry.STORED) {
          deflated.add(base);
        }
      }
      if (!deflated.isEmpty()) {
        bad.add(prefix + " has deflated .so entries (" + String.join(", ", deflated)
            + "); set nocompress_extensions = [\".so\"] on the android_binary");
      }
      for (Map.Entry<String, Expected> x : expected.entrySet()) {
        String entry = prefix + x.getKey();
        List<ZipEntry> found = apk.named(entry);
        if (found.size() != 1) {
          // Missing or duplicated: already reported above.
          continue;
        }
        ZipEntry ze = found.get(0);
        long want = x.getValue().crc;
        if (ze.getCrc() != want) {
          bad.add(String.format(
              "%s CRC %08x is not the declared %08x; the packaged library differs from the one the build declared",
              entry, ze.getCrc(), want));
        }
        report.add(String.format("%s crc=%08x = %s",
            entry, ze.getCrc(), Paths.get(x.getValue().source).getFileName()));
        checked++;
      }
    }
    report.add("checked " + checked + " native entries");
    return report;
  }

  private static Set<String> namesUnder(Apk apk, String prefix) {
    Set<String> out = new TreeSet<>();
    for (ZipEntry e : apk.all) {
      if (e.getName().startsWith(prefix)) {
        out.add(e.getName().substring(prefix.length()));
      }
    }
    return out;
  }

  private static long fileCrc(String path) throws IOException {
    CRC32 crc = new CRC32();
    try (InputStream in = Files.newInputStream(Paths.get(path))) {
      byte[] buf = new byte[1 << 16];
      int n;
      while ((n = in.read(buf)) != -1) {
        crc.update(buf, 0, n);
      }
    }
    return crc.getValue();
  }
}
