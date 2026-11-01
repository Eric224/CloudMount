import java.nio.file.*;
import java.net.URI;
import java.security.SecureRandom;
import org.cryptomator.cryptofs.*;
import org.cryptomator.cryptolib.api.*;
import org.cryptomator.cryptolib.common.MasterkeyFileAccess;

/** Test-only: executes the unmodified official cryptofs shipped in Cryptomator. */
public class CryptomatorInterop {
  public static void main(String[] args) throws Exception {
    var root = Path.of(args[1]);
    var password = new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
    var access = new MasterkeyFileAccess(new byte[0], new SecureRandom());
    var properties = CryptoFileSystemProperties.cryptoFileSystemProperties()
      .withKeyLoader(uri -> access.load(root.resolve("masterkey.cryptomator"), password)).build();
    if (args[0].equals("create")) {
      Files.createDirectories(root);
      try (var key = Masterkey.generate(new SecureRandom())) {
        access.persist(key, root.resolve("masterkey.cryptomator"), password);
      }
      CryptoFileSystemProvider.initialize(root, properties, URI.create("masterkeyfile:masterkey.cryptomator"));
    }
    try (var fs = CryptoFileSystemProvider.newFileSystem(root, properties)) {
      var p = fs.getPath("/");
      if (args[0].equals("edit")) {
        if (!Files.readString(p.resolve("中文資料/測試.txt")).equals("Swift 原始內容")) throw new AssertionError("Swift read");
        Files.writeString(p.resolve("中文資料/測試.txt"), "官方覆寫內容");
        Files.move(p.resolve("中文資料/" + "長".repeat(80) + ".txt"), p.resolve("官方改名.txt"));
        Files.delete(p.resolve("待刪除.txt"));
      }
      Files.createDirectory(p.resolve("官方建立"));
      Files.writeString(p.resolve("官方建立/跨平台.txt"), "Cryptomator 官方寫入");
      Files.writeString(p.resolve("官方建立/" + "長".repeat(80) + ".txt"), "官方長檔名");
    }
    System.out.println("official cryptofs interoperability OK");
  }
}
