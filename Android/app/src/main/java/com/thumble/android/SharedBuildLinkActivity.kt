package com.thumble.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** A transient handoff. Never serialize a bearer URL into MainActivity's launch state. */
internal object SharedBuildInbox {
    private var raw: String?=null
    @Synchronized fun offer(value: String) { raw=if(value.length<=2048) value else "https://${BuilderArtifactShare.HOST}/invalid" }
    @Synchronized fun take(): String?=raw.also { raw=null }
}
class SharedBuildLinkActivity: Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent.dataString?.let(SharedBuildInbox::offer)
        startActivity(Intent(this,MainActivity::class.java).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
