package com.thumble.android

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException

class SkinImportReaderTest {
    @Test fun exactLimitIsAcceptedAndStreamIsClosed() {
        var closed=false
        val input=object: ByteArrayInputStream(byteArrayOf(1,2,3)) { override fun close() { closed=true;super.close() } }
        assertArrayEquals(byteArrayOf(1,2,3),SkinImportReader.bytes({input},3));assertTrue(closed)
    }
    @Test fun overLimitIsRejectedBeforeWritingAndClosesTheStream() {
        var closed=false
        val input=object: ByteArrayInputStream(ByteArray(5)) { override fun close() { closed=true;super.close() } }
        assertTrue(runCatching { SkinImportReader.bytes({input},4) }.exceptionOrNull() is SkinImportException);assertTrue(closed)
    }
    @Test fun zeroLengthBulkReadMakesProgressWithoutLosingTheFirstByte() {
        var first=true
        val input=object: ByteArrayInputStream(byteArrayOf(7,8,9)) {
            override fun read(bytes: ByteArray,offset: Int,length: Int): Int {
                if(first) { first=false;return 0 };return super.read(bytes,offset,length)
            }
        }
        assertArrayEquals(byteArrayOf(7,8,9),SkinImportReader.bytes({input},3))
    }
    @Test fun permissionAndProviderErrorsDoNotExposeTheUri() {
        val denied=runCatching { SkinImportReader.packageValue { throw SecurityException("content://secret-token") } }.exceptionOrNull()!!
        assertTrue(denied.message!!.contains("expired"));assertFalse(denied.message!!.contains("secret-token"))
        val failed=runCatching { SkinImportReader.packageValue { throw IOException("content://secret-token") } }.exceptionOrNull()!!
        assertFalse(failed.message!!.contains("secret-token"))
    }
    @Test fun invalidArchiveNeverProducesAReviewPackage() {
        assertTrue(runCatching { SkinImportReader.packageValue { byteArrayOf(1,2,3).inputStream() } }.exceptionOrNull() is SkinImportException)
    }
}
