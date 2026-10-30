import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/** Plain-assertion tests for ApkCheck's collision, deflate and missing/stray rules. */
public class ApkCheckTest {
  private static final String ABI = "arm64-v8a";
  private static final String LABEL = "//app:app";

  public static void main(String[] args) throws IOException {
    sameSourceIsOk();
    sameCrcFromTwoArchivesIsOk();
    differentCrcFromTwoArchivesFails();
    fileAndArchiveFails();
    deflatedLibraryIsReported();
    missingAndStrayAreReported();
    linkedLibraryIsNotDeclared();
    System.out.println("ApkCheckTest: all passed");
  }

  private static void sameSourceIsOk() {
    ApkCheck.Spec s = new ApkCheck.Spec();
    ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(1, "a.so", false), LABEL);
    ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(1, "a.so", false), LABEL);
    assertEquals(1, s.expect.get(ABI).size(), "same source keeps one entry");
  }

  private static void sameCrcFromTwoArchivesIsOk() {
    ApkCheck.Spec s = new ApkCheck.Spec();
    ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(7, "a.zip", true), LABEL);
    ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(7, "b.zip", true), LABEL);
    assertEquals(1, s.expect.get(ABI).size(), "same CRC from two archives keeps one entry");
  }

  private static void differentCrcFromTwoArchivesFails() {
    ApkCheck.Spec s = new ApkCheck.Spec();
    ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(7, "a.zip", true), LABEL);
    expectFailure(
        "flutter_apk_check: //app:app: lib/arm64-v8a/libx.so is in a.zip and in b.zip with different CRC-32s",
        () -> ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(8, "b.zip", true), LABEL));
  }

  private static void fileAndArchiveFails() {
    ApkCheck.Spec s = new ApkCheck.Spec();
    ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(7, "a.so", false), LABEL);
    expectFailure(
        "flutter_apk_check: //app:app: lib/arm64-v8a/libx.so is in a.so and in b.zip; a library name must come from one source",
        () -> ApkCheck.addExpected(s, ABI, "libx.so", new ApkCheck.Expected(7, "b.zip", true), LABEL));
  }

  private static void deflatedLibraryIsReported() throws IOException {
    byte[] stored = "stored".getBytes(StandardCharsets.UTF_8);
    byte[] deflated = "deflated".getBytes(StandardCharsets.UTF_8);
    ApkCheck.Spec s = new ApkCheck.Spec();
    s.mode = "release";
    s.abis.add(ABI);
    ApkCheck.addExpected(s, ABI, "libstored.so", new ApkCheck.Expected(crc(stored), "s.so", false), LABEL);
    ApkCheck.addExpected(s, ABI, "libdeflated.so", new ApkCheck.Expected(crc(deflated), "d.so", false), LABEL);
    List<String> bad = checkApk(s, entry("lib/" + ABI + "/libstored.so", stored, true),
        entry("lib/" + ABI + "/libdeflated.so", deflated, false));
    assertEquals(
        Arrays.asList(
            "lib/arm64-v8a/ has deflated .so entries (libdeflated.so); set nocompress_extensions = [\".so\"] on the android_binary"),
        bad,
        "deflated .so entry");
  }

  private static void missingAndStrayAreReported() throws IOException {
    byte[] present = "present".getBytes(StandardCharsets.UTF_8);
    byte[] stray = "stray".getBytes(StandardCharsets.UTF_8);
    ApkCheck.Spec s = new ApkCheck.Spec();
    s.mode = "release";
    s.abis.add(ABI);
    ApkCheck.addExpected(s, ABI, "libpresent.so", new ApkCheck.Expected(crc(present), "p.so", false), LABEL);
    ApkCheck.addExpected(s, ABI, "libmissing.so", new ApkCheck.Expected(1, "m.so", false), LABEL);
    List<String> bad = checkApk(s, entry("lib/" + ABI + "/libpresent.so", present, true),
        entry("lib/" + ABI + "/stray.so", stray, true));
    assertEquals(
        Arrays.asList(
            "missing lib/arm64-v8a/libmissing.so",
            "lib/arm64-v8a/stray.so is not declared by the native inputs"),
        bad,
        "missing and stray entries");
  }

  // A library linked into a split's CcInfo is not a declared input: the spec holds only
  // the split's FlutterSplitNativeInfo files, so the APK's copy is stray.
  private static void linkedLibraryIsNotDeclared() throws IOException {
    byte[] declared = "declared".getBytes(StandardCharsets.UTF_8);
    byte[] linked = "linked".getBytes(StandardCharsets.UTF_8);
    ApkCheck.Spec s = new ApkCheck.Spec();
    s.mode = "release";
    s.abis.add(ABI);
    ApkCheck.addExpected(s, ABI, "libdeclared.so", new ApkCheck.Expected(crc(declared), "d.so", false), LABEL);
    List<String> bad = checkApk(s, entry("lib/" + ABI + "/libdeclared.so", declared, true),
        entry("lib/" + ABI + "/libstray_probe.so", linked, true));
    assertEquals(
        Arrays.asList("lib/arm64-v8a/libstray_probe.so is not declared by the native inputs"),
        bad,
        "linked library not declared");
  }

  // One entry to write into a test APK: its name, bytes, and whether it is stored.
  private static final class Entry {
    final String name;
    final byte[] data;
    final boolean stored;

    Entry(String name, byte[] data, boolean stored) {
      this.name = name;
      this.data = data;
      this.stored = stored;
    }
  }

  private static Entry entry(String name, byte[] data, boolean stored) {
    return new Entry(name, data, stored);
  }

  private static List<String> checkApk(ApkCheck.Spec s, Entry... entries) throws IOException {
    Path dir = Files.createTempDirectory("apk_check_test");
    Path apk = dir.resolve("app.apk");
    try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(apk))) {
      for (Entry e : entries) {
        ZipEntry z = new ZipEntry(e.name);
        if (e.stored) {
          z.setMethod(ZipEntry.STORED);
          z.setSize(e.data.length);
          z.setCompressedSize(e.data.length);
          z.setCrc(crc(e.data));
        }
        out.putNextEntry(z);
        out.write(e.data);
        out.closeEntry();
      }
    }
    List<String> bad = new ArrayList<>();
    try (ZipFile zip = new ZipFile(apk.toFile())) {
      ApkCheck.check(s, zip, bad);
    }
    return bad;
  }

  private static long crc(byte[] data) {
    CRC32 crc = new CRC32();
    crc.update(data);
    return crc.getValue();
  }

  private interface Body {
    void run();
  }

  private static void expectFailure(String want, Body body) {
    try {
      body.run();
    } catch (ApkCheck.CheckFailure e) {
      assertEquals(want, e.getMessage(), "failure message");
      return;
    }
    throw new AssertionError("no failure; want: " + want);
  }

  private static void assertEquals(Object want, Object got, String what) {
    if (!want.equals(got)) {
      throw new AssertionError(what + ": want " + want + ", got " + got);
    }
  }

  private static void assertEquals(int want, int got, String what) {
    if (want != got) {
      throw new AssertionError(what + ": want " + want + ", got " + got);
    }
  }
}
