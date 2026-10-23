import expo.modules.tappinglink.DatagramCipher;
import java.util.HexFormat;
import java.nio.charset.StandardCharsets;
public class CipherFixture {
  public static void main(String[] args) throws Exception {
    byte[] key = new byte[32]; for(int i=0;i<32;i++) key[i]=(byte)i;
    var client=new DatagramCipher(key,false); var server=new DatagramCipher(key,true);
    var packet=client.seal("test".getBytes(StandardCharsets.UTF_8));
    System.out.println("FIXTURE "+HexFormat.of().formatHex(packet));
    if(!new String(server.open(packet),StandardCharsets.UTF_8).equals("test")) throw new AssertionError();
    try {server.open(packet);throw new AssertionError("replay accepted");}catch(java.security.GeneralSecurityException expected){}
    var forged=client.seal(new byte[]{1}); forged[11]=100;
    try {server.open(forged);throw new AssertionError("forgery accepted");}catch(java.security.GeneralSecurityException expected){}
    if(server.open(client.seal(new byte[]{2}))[0]!=2)throw new AssertionError();
    System.out.println("PASS Java AES-GCM, replay, forged-counter rejection");
  }
}
