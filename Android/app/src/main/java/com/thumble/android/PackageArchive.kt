package com.thumble.android

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.zip.CRC32
import java.util.zip.Inflater

internal class SkinPackageException(val code: String): IllegalArgumentException("Skin package rejected: $code")

/** Central-directory-driven bounded ZIP reader. No archive path ever reaches the filesystem. */
internal object PackageArchive {
    const val MAX_ARCHIVE = 40 * 1024 * 1024
    const val MAX_ENTRY = 10 * 1024 * 1024
    const val MAX_TOTAL = 50 * 1024 * 1024
    private fun check(ok: Boolean,code: String="invalid-archive") { if (!ok) throw SkinPackageException(code) }
    internal data class Entry(val path: String,val size: Int,val compressed: Int,val crc: Long,
        val method: Int,val flags: Int,val offset: Int,val rawName: ByteArray)
    class Index internal constructor(private val bytes: ByteArray,private val entries: Map<String,Entry>) {
        val paths get() = entries.keys.toSet()
        fun extract(path: String,limit: Int=MAX_ENTRY): ByteArray {
            val e=entries[path] ?: throw SkinPackageException("missing-entry")
            check(e.size <= limit,"entry-too-large")
            val local=e.offset
            check(u32(bytes,local)==0x04034b50L)
            check(u16(bytes,local+6)==e.flags && u16(bytes,local+8)==e.method)
            val length=u16(bytes,local+26);val extra=u16(bytes,local+28)
            check(local.toLong()+30+length+extra+e.compressed <= bytes.size)
            check(bytes.copyOfRange(local+30,local+30+length).contentEquals(e.rawName))
            val start=local+30+length+extra
            val result=if (e.method == 0) {
                check(e.compressed==e.size);bytes.copyOfRange(start,start+e.size)
            } else {
                val inflater=Inflater(true)
                try {
                    inflater.setInput(bytes,start,e.compressed)
                    val result=ByteArrayOutputStream(e.size)
                    val buffer=ByteArray(64*1024)
                    while (!inflater.finished()) {
                        val count=inflater.inflate(buffer)
                        check(result.size().toLong()+count <= e.size,"entry-too-large")
                        result.write(buffer,0,count)
                        check(count>0 || inflater.finished(),"corrupt-entry")
                    }
                    check(inflater.remaining==0,"corrupt-entry")
                    result.toByteArray()
                } catch (e: SkinPackageException) { throw e }
                catch (_: Exception) { throw SkinPackageException("corrupt-entry") }
                finally { inflater.end() }
            }
            check(result.size==e.size && crc(result)==e.crc,"corrupt-entry")
            return result
        }
    }
    fun safePath(path: String,root: String?=null): Boolean {
        if (path.isEmpty() || path.startsWith('/') || path.startsWith('~') || '\\' in path || '\u0000' in path) return false
        val parts=path.removeSuffix("/").split('/')
        return parts.none { it.isEmpty() || it=="." || it==".." } && (root==null || parts.size>=2 && parts.first()==root)
    }
    fun index(bytes: ByteArray): Index {
        check(bytes.size<=MAX_ARCHIVE,"archive-too-large");check(bytes.size>=22)
        val end=(bytes.size-22 downTo maxOf(0,bytes.size-65557)).firstOrNull {
            u32(bytes,it)==0x06054b50L && it+22+u16(bytes,it+20)==bytes.size
        } ?: throw SkinPackageException("invalid-archive")
        check(u16(bytes,end+4)==0 && u16(bytes,end+6)==0)
        var count=u16(bytes,end+10).toLong();var size=u32(bytes,end+12);var offset=u32(bytes,end+16)
        check(u16(bytes,end+8).toLong()==count)
        if (count==65535L || size==0xffffffffL || offset==0xffffffffL) {
            check(end>=20 && u32(bytes,end-20)==0x07064b50L && u32(bytes,end-16)==0L && u32(bytes,end-4)==1L)
            val record=bounded(u64(bytes,end-12),bytes.size-56)
            check(u32(bytes,record)==0x06064b50L && u64(bytes,record+4)>=44 && u64(bytes,record+4)<=bytes.size-12 && record.toLong()+12+u64(bytes,record+4)<=end-20 && u32(bytes,record+16)==0L && u32(bytes,record+20)==0L)
            count=u64(bytes,record+32);check(u64(bytes,record+24)==count)
            size=u64(bytes,record+40);offset=u64(bytes,record+48)
            check(offset+size<=record)
        }
        check(count<=256,"too-many-entries")
        check(offset+size<=end && offset>=0 && size>=0)
        var cursor=bounded(offset,bytes.size);val stop=bounded(offset+size,bytes.size)
        var total=0L;val seen=mutableSetOf<String>();val entries=linkedMapOf<String,Entry>();val ranges=mutableListOf<IntRange>()
        repeat(count.toInt()) {
            check(cursor+46<=stop && u32(bytes,cursor)==0x02014b50L)
            val flags=u16(bytes,cursor+8);val method=u16(bytes,cursor+10)
            check(flags and 0x41==0,"unsupported-entry");check(method==0 || method==8,"unsupported-entry")
            val nameSize=u16(bytes,cursor+28);val extraSize=u16(bytes,cursor+30);val commentSize=u16(bytes,cursor+32)
            val next=cursor+46+nameSize+extraSize+commentSize;check(next<=stop)
            val rawName=bytes.copyOfRange(cursor+46,cursor+46+nameSize)
            val path=try {
                val charset=if (flags and 2048 != 0) Charsets.UTF_8 else charset("Cp437")
                charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(rawName)).toString()
            } catch (_: Exception) { throw SkinPackageException("unsafe-entry") }
            check(safePath(path),"unsafe-entry");check(seen.add(path),"duplicate-entry")
            val mode=(u32(bytes,cursor+38) shr 16).toInt() and 0xf000
            check(mode in listOf(0,0x8000,0x4000),"unsupported-entry")
            val directory=path.endsWith('/') || mode==0x4000 || u32(bytes,cursor+38) and 0x10L != 0L
            var compressed=u32(bytes,cursor+20);var length=u32(bytes,cursor+24);var local=u32(bytes,cursor+42)
            var disk=u16(bytes,cursor+34).toLong()
            if (compressed==0xffffffffL || length==0xffffffffL || local==0xffffffffL || disk==65535L) {
                var extra=cursor+46+nameSize;val extraEnd=extra+extraSize;var found=false
                while (extra+4<=extraEnd) {
                    val tag=u16(bytes,extra);val n=u16(bytes,extra+2);extra+=4;check(extra+n<=extraEnd)
                    if (tag==1) {
                        var p=extra
                        fun next64(): Long { check(p+8<=extra+n);return u64(bytes,p).also { p+=8 } }
                        if (length==0xffffffffL) length=next64()
                        if (compressed==0xffffffffL) compressed=next64()
                        if (local==0xffffffffL) local=next64()
                        if (disk==65535L) { check(p+4<=extra+n);disk=u32(bytes,p) }
                        found=true;break
                    }
                    extra+=n
                }
                check(found)
            }
            check(disk==0L)
            check(length<=MAX_ENTRY,"entry-too-large");check(compressed<=MAX_ARCHIVE)
            if (!directory) {
                total+=length;check(total<=MAX_TOTAL,"archive-too-large")
                check(compressed==0L || length/compressed<=200,"compression-ratio-too-high")
                val start=bounded(local,bytes.size-30)
                check(u32(bytes,start)==0x04034b50L)
                val dataEnd=start.toLong()+30+u16(bytes,start+26)+u16(bytes,start+28)+compressed
                check(dataEnd<=offset)
                ranges.add(start until bounded(dataEnd,bytes.size))
                entries[path]=Entry(path,length.toInt(),compressed.toInt(),u32(bytes,cursor+16),method,flags,start,rawName)
            }
            cursor=next
        }
        check(cursor==stop)
        val sorted=ranges.sortedBy { it.first }
        for (i in 1 until sorted.size) check(sorted[i-1].last<sorted[i].first)
        return Index(bytes,entries)
    }
    private fun bounded(value: Long,maximum: Int): Int { check(value>=0 && value<=maximum);return value.toInt() }
    private fun u16(b: ByteArray,p: Int): Int { check(p>=0 && p.toLong()+2<=b.size);return (b[p].toInt() and 255) or ((b[p+1].toInt() and 255) shl 8) }
    private fun u32(b: ByteArray,p: Int): Long = u16(b,p).toLong() or (u16(b,p+2).toLong() shl 16)
    private fun u64(b: ByteArray,p: Int): Long { val high=u32(b,p+4);check(high<=0x7fffffff);return u32(b,p) or (high shl 32) }
    private fun crc(b: ByteArray) = CRC32().apply { update(b) }.value
}
