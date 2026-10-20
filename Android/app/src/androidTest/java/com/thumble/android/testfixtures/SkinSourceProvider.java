package com.thumble.android.testfixtures;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/** This provider is not exported; the receiving app must possess the sender's URI grant. */
public final class SkinSourceProvider extends ContentProvider {
    private final ConcurrentHashMap<String,AtomicInteger> opens=new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String,java.util.concurrent.CountDownLatch> gates=new ConcurrentHashMap<>();
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "application/vnd.pocketpad.skin+zip"; }
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws FileNotFoundException {
        if(!"r".equals(mode)) throw new FileNotFoundException("Read-only fixture");
        opens.computeIfAbsent(uri.toString(),k -> new AtomicInteger()).incrementAndGet();
        String fixture=uri.getLastPathSegment();
        String name;
        if("slow-solar".equals(fixture)) {
            try {
                if(!gates.computeIfAbsent(uri.toString(),k -> new java.util.concurrent.CountDownLatch(1)).await(60,java.util.concurrent.TimeUnit.SECONDS))
                    throw new FileNotFoundException("Fixture wait expired");
            } catch(InterruptedException error) { Thread.currentThread().interrupt();throw new FileNotFoundException("Fixture interrupted"); }
        }
        if("solar".equals(fixture) || "slow-solar".equals(fixture) || "denied-solar".equals(fixture)) name="solar-sumi-1.0.0-edbecde5b708.pocketpad";
        else if("foldline".equals(fixture)) name="foldline-relay-1.0.0-d04c121e9b0a.pocketpad";
        else if("invalid".equals(fixture)) name=null;
        else throw new FileNotFoundException("Unknown fixture");
        File file=null;
        try {
            file=File.createTempFile("skin-source-",".pocketpad",getContext().getCacheDir());
            try(OutputStream output=new FileOutputStream(file)) {
                if(name==null) output.write(new byte[]{1,2,3});
                else try(InputStream input=getContext().getAssets().open(name)) {
                    byte[] buffer=new byte[65536];int n;
                    while((n=input.read(buffer))!=-1) output.write(buffer,0,n);
                }
            }
            ParcelFileDescriptor result=ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY);
            file.delete();return result;
        } catch(IOException error) { if(file!=null) file.delete();throw new FileNotFoundException("Fixture unavailable"); }
    }
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort) {
        String[] columns=projection==null ? new String[]{OpenableColumns.DISPLAY_NAME,"openCount"} : projection;
        MatrixCursor cursor=new MatrixCursor(columns);Object[] values=new Object[columns.length];
        for(int i=0;i<columns.length;i++) {
            if(OpenableColumns.DISPLAY_NAME.equals(columns[i])) values[i]=uri.getLastPathSegment()+".pocketpad";
            else if("openCount".equals(columns[i])) values[i]=opens.getOrDefault(uri.toString(),new AtomicInteger()).get();
            else if("release".equals(columns[i])) { gates.computeIfAbsent(uri.toString(),k -> new java.util.concurrent.CountDownLatch(1)).countDown();values[i]=1; }
        }
        cursor.addRow(values);return cursor;
    }
    @Override public Uri insert(Uri uri,ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri,String selection,String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args) { throw new UnsupportedOperationException(); }
}
