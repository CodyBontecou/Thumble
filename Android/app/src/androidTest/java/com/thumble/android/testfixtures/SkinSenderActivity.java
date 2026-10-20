package com.thumble.android.testfixtures;

import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.content.ClipData;
import android.net.Uri;

/** Separate test APK/UID supplies the same temporary grant as an external Files/share app. */
public final class SkinSenderActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String fixture=getIntent().getStringExtra("fixture");
        if(fixture==null) fixture="solar";
        String mode=getIntent().getStringExtra("mode");
        if("denied".equals(mode)) fixture="denied-solar";
        Uri uri=new Uri.Builder().scheme("content").authority("com.thumble.android.test.skin-source")
            .appendPath(fixture).appendQueryParameter("nonce",getIntent().getStringExtra("nonce")).build();
        Intent outgoing=new Intent("view".equals(mode) || "denied".equals(mode) ? Intent.ACTION_VIEW : Intent.ACTION_SEND)
            .setPackage("com.thumble.android").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if(Intent.ACTION_VIEW.equals(outgoing.getAction())) outgoing.setDataAndType(uri,"application/vnd.pocketpad.skin+zip");
        else {
            outgoing.setType("application/vnd.pocketpad.skin+zip");
            if(!"clip".equals(mode)) outgoing.putExtra(Intent.EXTRA_STREAM,uri);
            outgoing.setClipData(ClipData.newRawUri("Skin fixture",uri));
        }
        if(!"denied".equals(mode)) outgoing.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(outgoing);
        finish();
    }
}
