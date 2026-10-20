package com.thumble.android.testfixtures;
import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

/** Separate UID models an external browser. Its link extra is only a fictional test token. */
public final class SharedBuildSenderActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Intent open=new Intent(Intent.ACTION_VIEW,Uri.parse(getIntent().getStringExtra("link")))
            .setClassName("com.thumble.android","com.thumble.android.SharedBuildLinkActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(open);finish();
    }
}
