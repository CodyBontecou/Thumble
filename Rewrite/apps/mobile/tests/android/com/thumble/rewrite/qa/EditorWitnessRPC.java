package com.thumble.rewrite.qa;

import android.content.Context;
import com.thumble.rewrite.input.*;
import java.net.InetSocketAddress;
import org.json.JSONObject;

/** Test-only Java interoperability with the existing internal Kotlin RPC adapter. */
final class EditorWitnessRPC {
  static JSONObject verify(TrustedHostEndpoint endpoint, Context context, EditorLabelIntent intent) throws Exception {
    PhoneCredentialVault vault = new PhoneCredentialVault(context);
    PhoneEditorRPC rpc = new PhoneEditorRPC(endpoint, () -> {
      ControlTLSClient client = ControlTLSClient.Companion.connect(
          new InetSocketAddress(endpoint.getHost(), endpoint.getPort()), endpoint.getCertificatePin());
      return new NativeFrameIO() {
        public void send(ControlTLSFrame frame) { client.send(frame); }
        public ControlTLSFrame receive() { return client.receive(); }
        public void close() { client.close(); }
      };
    }, (pin, now) -> vault.load(pin, now), System::currentTimeMillis);
    try {
      EditorReply first = rpc.exchange(new EditorRequest.Status(intent)).getReply();
      if (!(first instanceof EditorReply.Committed)) throw new IllegalStateException("paired_exact_status");
      EditorReceipt receipt = ((EditorReply.Committed) first).getReceipt();
      EditorReply replay = rpc.exchange(new EditorRequest.Label(intent)).getReply();
      EditorReply last = rpc.exchange(new EditorRequest.Status(intent)).getReply();
      if (!(replay instanceof EditorReply.Committed) || !(last instanceof EditorReply.Committed))
        throw new IllegalStateException("paired_exact_replay");
      EditorReceipt second = ((EditorReply.Committed) replay).getReceipt();
      EditorReceipt third = ((EditorReply.Committed) last).getReceipt();
      if (!receipt.getRevision().equals(new java.math.BigInteger(intent.getExpectedRevision()).add(java.math.BigInteger.ONE).toString()) || !receipt.getHash().matches("[0-9a-f]{64}") || !receipt.getOperationID().equals(intent.getOperationID()) ||
          !receipt.getRevision().equals(second.getRevision()) || !receipt.getHash().equals(second.getHash()) ||
          !receipt.getRevision().equals(third.getRevision()) || !receipt.getHash().equals(third.getHash()) ||
          !receipt.getEntities().equals(java.util.Arrays.asList(intent.getProfileID(), intent.getControlID())))
        throw new IllegalStateException("paired_receipt_changed");
      return new JSONObject().put("operationId", receipt.getOperationID())
          .put("revision", receipt.getRevision()).put("hash", receipt.getHash())
          .put("exactStatus", true).put("duplicateCommitted", true);
    } finally { rpc.cancel(); }
  }
}
