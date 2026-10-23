package expo.modules.tappinglink;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class DatagramCipher {
  private final SecretKeySpec key;
  private final int sending, receiving;
  private long counter = 0, received = 0;
  private static final byte[] CONTEXT = "tapping-udp-v1".getBytes(StandardCharsets.UTF_8);
  public DatagramCipher(byte[] key, boolean server) {
    if (key.length != 32) throw new IllegalArgumentException("Invalid datagram key");
    this.key = new SecretKeySpec(key, "AES"); sending = server ? 2 : 1; receiving = server ? 1 : 2;
  }
  public synchronized byte[] seal(byte[] clear) throws GeneralSecurityException {
    if (clear.length > 1100 || counter == Long.MAX_VALUE) throw new GeneralSecurityException("Datagram limit");
    byte[] nonce = ByteBuffer.allocate(12).putInt(sending).putLong(++counter).array();
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, nonce)); cipher.updateAAD(CONTEXT);
    byte[] encrypted = cipher.doFinal(clear);
    return ByteBuffer.allocate(12 + encrypted.length).put(nonce).put(encrypted).array();
  }
  public synchronized byte[] open(byte[] packet) throws GeneralSecurityException {
    if (packet.length < 28 || packet.length > 1128) throw new GeneralSecurityException("Datagram size");
    ByteBuffer header = ByteBuffer.wrap(packet);
    int direction = header.getInt(); long sequence = header.getLong();
    if (direction != receiving || sequence <= received) throw new GeneralSecurityException("Datagram replay");
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, Arrays.copyOfRange(packet, 0, 12))); cipher.updateAAD(CONTEXT);
    byte[] clear = cipher.doFinal(packet, 12, packet.length - 12);
    received = sequence;
    return clear;
  }
}
