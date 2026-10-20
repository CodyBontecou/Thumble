package com.thumble.android

import java.net.URI
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

internal class SharedBuildException(val code: String): IllegalArgumentException(messageFor(code)) {
    companion object {
        private fun messageFor(code: String)=when(code) {
            "unsupported-origin" -> "This shared-build link is from an unsupported server."
            "invalid-token" -> "This shared-build link has invalid authorization."
            "invalid-path" -> "This shared-build link has an invalid artifact identifier."
            "unsafe-response" -> "The shared-build server returned an unsafe response."
            "unavailable" -> "The shared build is unavailable or expired."
            "unsupported-format" -> "The shared-build server returned an unsupported format."
            "too-large" -> "The shared build exceeds the size limit."
            "download-failed" -> "The shared build could not be downloaded."
            "invalid-artifact" -> "The shared build failed Thumble’s safety or integrity checks."
            else -> "This is not a valid Thumble shared-build link."
        }
    }
}

/** Transient authorization. No generated copy, component or string methods can expose it. */
internal class BuilderArtifactShare private constructor(val artifactID: String,val requestURI: URI,val sourceHost: String,private val token: String) {
    internal fun authorize(request: Request.Builder)=request.header("Authorization","ThumbleShare $token")
    override fun toString()="BuilderArtifactShare([redacted])"
    companion object {
        const val HOST="thumble-mcp-gateway.fly.dev"
        private val artifactID=Regex("bar_[0-9a-fA-F]{64}")
        private val token=Regex("[0-9a-fA-F]{64}")
        fun parse(raw: String,localTesting: Boolean=false): BuilderArtifactShare {
            fun fail(code: String): Nothing = throw SharedBuildException(code)
            if(raw.isEmpty() || raw.toByteArray(Charsets.UTF_8).size>2048 || raw.codePoints().anyMatch(SkinText::isControl)) fail("invalid-link")
            val uri=try { URI(raw) } catch(_: Exception) { fail("invalid-link") }
            val host=uri.host ?: fail("invalid-link")
            if(uri.rawUserInfo!=null || uri.rawQuery!=null || host!=host.lowercase()) fail("invalid-link")
            val production=uri.scheme=="https" && host==HOST && uri.port==-1
            val loopback=localTesting && uri.scheme in setOf("http","https") && host in setOf("localhost","127.0.0.1","::1","[::1]") && uri.port in 0..65535
            if(!production && !loopback) fail("unsupported-origin")
            val path=uri.rawPath ?: fail("invalid-path")
            if(!path.startsWith("/share/") || '%' in path || !artifactID.matches(path.removePrefix("/share/"))) fail("invalid-path")
            val fragment=uri.rawFragment ?: fail("invalid-token")
            if(!fragment.startsWith("token=") || !token.matches(fragment.removePrefix("token="))) fail("invalid-token")
            val target="${uri.scheme}://${uri.rawAuthority}$path"
            if(raw!="$target#$fragment") fail("invalid-link")
            return BuilderArtifactShare(path.removePrefix("/share/"),URI(target),host,fragment.removePrefix("token="))
        }
        fun resembles(raw: String): Boolean {
            val text=raw.trim().lowercase()
            return ((text.startsWith("https://") || text.startsWith("http://")) && "/share/" in text) || HOST in text || "#token=" in text
        }
    }
}

/** No cookies, credentials, redirects, cache, or retries; body is bounded while streaming. */
internal class BuilderArtifactFetcher(private val http: OkHttpClient=OkHttpClient.Builder()
    .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
    .connectTimeout(15,TimeUnit.SECONDS).readTimeout(15,TimeUnit.SECONDS).callTimeout(15,TimeUnit.SECONDS).build()) {
    fun fetch(reference: BuilderArtifactShare,complete: (Result<ByteArray>)->Unit): Call {
        val request=reference.authorize(Request.Builder().url(reference.requestURI.toASCIIString())).header("Accept","application/json").get().build()
        val call=http.newCall(request)
        call.enqueue(object: Callback {
            override fun onFailure(call: Call,error: IOException) { complete(Result.failure(SharedBuildException("download-failed"))) }
            override fun onResponse(call: Call,response: Response) {
                val result=runCatching { response.use { value ->
                    if(value.code in 300..399 || value.request.url.toString()!=reference.requestURI.toASCIIString()) throw SharedBuildException("unsafe-response")
                    if(value.code!=200) throw SharedBuildException("unavailable")
                    val body=value.body ?: throw SharedBuildException("download-failed")
                    val type=body.contentType()
                    if(type?.type!="application" || type.subtype!="json") throw SharedBuildException("unsupported-format")
                    val length=body.contentLength()
                    if(length < -1 || length>PortableProfileArtifact.MAX_BYTES) throw SharedBuildException("too-large")
                    val output=ByteArrayOutputStream(64*1024);val buffer=ByteArray(64*1024)
                    body.byteStream().use { input ->
                        while(true) {
                            if(call.isCanceled()) throw SharedBuildException("download-failed")
                            val count=input.read(buffer);if(count<0) break
                            if(output.size().toLong()+count>PortableProfileArtifact.MAX_BYTES) throw SharedBuildException("too-large")
                            output.write(buffer,0,count)
                        }
                    }
                    output.toByteArray()
                } }.recoverCatching { error -> throw error as? SharedBuildException ?: SharedBuildException("download-failed") }
                complete(result)
            }
        })
        return call
    }
}
