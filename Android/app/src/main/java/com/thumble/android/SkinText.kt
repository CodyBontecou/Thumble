package com.thumble.android

/** Skin text utilities; grapheme and character categories use pinned native tables. */
internal object SkinText {
    private fun property(table: IntArray, scalar: Int): Int {
        var low=0;var high=table.size/3-1
        while(low<=high) {
            val middle=(low+high) ushr 1;val at=middle*3
            when { scalar<table[at] -> high=middle-1;scalar>table[at+1] -> low=middle+1;else -> return table[at+2] }
        }
        return 0
    }
    fun isAlphanumeric(scalar: Int) = property(SkinUnicodeData.alphanumeric,scalar)!=0
    fun isControl(scalar: Int) = property(SkinUnicodeData.control,scalar)!=0
    fun isWhitespace(scalar: Int) = property(SkinUnicodeData.whitespace,scalar)!=0
    fun trim(value: String): String {
        var start=0;var end=value.length
        while(start<end && isWhitespace(Character.codePointAt(value,start))) start+=Character.charCount(Character.codePointAt(value,start))
        while(end>start && isWhitespace(Character.codePointBefore(value,end))) end-=Character.charCount(Character.codePointBefore(value,end))
        return value.substring(start,end)
    }
    /** Swift String identity treats canonically equivalent spellings as equal. */
    fun canonicalKey(value: String): String = if(value.all { it.code<128 }) value else
        java.text.Normalizer.normalize(value,java.text.Normalizer.Form.NFC)
    fun isWellFormed(value: String): Boolean {
        var at=0
        while(at<value.length) {
            val c=value[at++]
            if(Character.isHighSurrogate(c)) {
                if(at==value.length || !Character.isLowSurrogate(value[at++])) return false
            } else if(Character.isLowSurrogate(c)) return false
        }
        return true
    }
    private fun grapheme(scalar: Int): Int = if(scalar in 0xAC00..0xD7A3) {
        if((scalar-0xAC00)%28==0) 12 else 13
    } else property(SkinUnicodeData.grapheme,scalar)

    // Extended grapheme rules GB3–GB13 with native runtime property tables. State summarizes
    // lookbehind so even a very long combining sequence is traversed once.
    fun prefix(value: String,limit: Int): String {
        if(limit<=0) return ""
        var offset=0;var count=0;var previous=0;var regional=0;var emoji=0;var indic=0
        while(offset<value.length) {
            val scalar=Character.codePointAt(value,offset);val current=grapheme(scalar)
            val pictographic=property(SkinUnicodeData.pictographic,scalar)!=0
            val conjunct=property(SkinUnicodeData.indic,scalar)
            val boundary=when {
                offset==0 -> true
                previous==1 && current==2 -> false
                previous in 1..3 || current in 1..3 -> true
                previous==9 && (current==9 || current==10 || current==12 || current==13) -> false
                (previous==10 || previous==12) && (current==10 || current==11) -> false
                (previous==11 || previous==13) && current==11 -> false
                current==4 || current==5 || current==8 || previous==7 -> false
                indic==2 && conjunct==1 -> false
                emoji==2 && pictographic -> false
                previous==6 && current==6 && regional%2==1 -> false
                else -> true
            }
            if(boundary) { if(count==limit) return value.substring(0,offset);count++ }
            emoji=when { pictographic -> 1;current==4 && emoji==1 -> 1;current==5 && emoji==1 -> 2;else -> 0 }
            indic=when { conjunct==1 -> 1;conjunct==3 && indic!=0 -> 2;conjunct==2 -> indic;else -> 0 }
            regional=if(current==6) regional+1 else 0
            previous=current;offset+=Character.charCount(scalar)
        }
        return value
    }
}
