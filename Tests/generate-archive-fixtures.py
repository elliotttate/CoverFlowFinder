#!/usr/bin/env python3
"""Test-only fixture generation; the shipping app never runs 7zz."""
import base64, io, os, pathlib, shutil, struct, subprocess, sys, tarfile, zipfile, zlib
root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
tool = shutil.which('7zz') or '/opt/homebrew/bin/7zz'
text = b'archive regression\n'
def png_chunk(kind, data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
png = b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+png_chunk(b'IDAT',zlib.compress(b'\x00\xff\x00\x00\xff'))+png_chunk(b'IEND',b'')
for name, method in [('stored',zipfile.ZIP_STORED),('deflate',zipfile.ZIP_DEFLATED),('bzip2',zipfile.ZIP_BZIP2),('lzma',zipfile.ZIP_LZMA)]:
    with zipfile.ZipFile(root/(name+'.zip'),'w',compression=method) as z:
        z.writestr('folder/hello.txt',text); z.writestr('folder/empty.txt',b''); z.writestr('folder/pixel.png',png)
for name, data in [('first.zip', b'first archive\n'), ('second.zip', b'second archive\n')]:
    with zipfile.ZipFile(root/name,'w',compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr('hello.txt',data)
with zipfile.ZipFile(root/'empty.zip','w'): pass
source = root/'input'; source.mkdir()
(source/'method.txt').write_bytes(text*1024)
(source/'hello.txt').write_bytes(text); (source/'pixel.png').write_bytes(png)
(source/'empty.txt').write_bytes(b'')
(source/'big.bin').write_bytes(os.urandom(192*1024))
def seven(name, flags, paths=['hello.txt','pixel.png','empty.txt']):
    subprocess.run([tool,'a','-bd','-y',str(root/name),*flags,*paths],cwd=source,check=True,stdout=subprocess.DEVNULL)
seven('solid.7z',['-t7z','-ms=on'])
seven('headers.7z',['-t7z','-psecret','-mhe=on'])
seven('password.7z',['-t7z','-psecret','-mhe=off'])
seven('aes.zip',['-tzip','-psecret','-mem=AES256'])
seven('zipcrypto.zip',['-tzip','-psecret','-mem=ZipCrypto'])
seven('deflate64.zip',['-tzip','-mm=Deflate64'],['hello.txt','pixel.png','empty.txt','method.txt'])
seven('ppmd.zip',['-tzip','-mm=PPMd'],['hello.txt','pixel.png','empty.txt','method.txt'])
seven('multi.7z',['-t7z','-v32k'],['big.bin'])
seven('multi.zip',['-tzip','-v32k'],['big.bin'])
subprocess.run(['/usr/bin/zip','-q','-s','64k',str(root/'spanned.zip'),'big.bin'],cwd=source,check=True)
for name,mode in [('links.tar','w'),('bundle.tar.gz','w:gz'),('bundle.tar.xz','w:xz'),('bundle.tar.bz2','w:bz2')]:
    with tarfile.open(root/name,mode) as t:
        for path,data in [('folder/hello.txt',text),('folder/pixel.png',png),('folder/empty.txt',b'')]:
            info=tarfile.TarInfo(path);info.size=len(data);info.mode=0o644;info.mtime=1700000000
            t.addfile(info,io.BytesIO(data))
        for path,target,kind in [('folder/relative','hello.txt',tarfile.SYMTYPE),('folder/escape','../../outside',tarfile.SYMTYPE),('folder/hard','folder/hello.txt',tarfile.LNKTYPE),('folder/brokenhard','../../outside',tarfile.LNKTYPE)]:
            info=tarfile.TarInfo(path);info.type=kind;info.linkname=target;info.mode=0o777;t.addfile(info)
with zipfile.ZipFile(root/'nested.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
    z.write(root/'solid.7z','folder/inner.7z');z.write(root/'headers.7z','encrypted.7z');z.write(root/'bundle.tar.gz','bundle.tar.gz')
with zipfile.ZipFile(root/'unsafe.zip','w',compression=zipfile.ZIP_BZIP2) as z:
    for path in ['../outside.txt','/absolute.txt','folder/../escape.txt','folder//emptycomponent.txt','folder/safe.txt','folder/A.txt','folder/a.txt']:
        z.writestr(path,text)
    # Data followed by a symlink cannot redirect a later member outside the private directory.
    i=zipfile.ZipInfo('folder/link');i.create_system=3;i.external_attr=0o120777<<16;z.writestr(i,b'../../outside')
    z.writestr('folder/link/child.txt',text)
# Corrupt the expected CRC (leaving the metadata valid) to exercise per-item errors from the engine.
blob=bytearray((root/'bzip2.zip').read_bytes());p=blob.index(b'PK\x01\x02');blob[p+16]^=1;blob[14]^=1;(root/'corrupt.zip').write_bytes(blob)
# A valid data stream with a damaged directory count: opening can succeed with error flags.
blob=bytearray((root/'stored.zip').read_bytes());p=blob.index(b'PK\x05\x06');struct.pack_into('<H',blob,p+8,4);struct.pack_into('<H',blob,p+10,4);(root/'bad-headers.zip').write_bytes(blob)
# Small file with a malicious declared size; no large data allocation is needed.
blob=bytearray((root/'stored.zip').read_bytes());p=blob.index(b'PK\x01\x02');struct.pack_into('<I',blob,p+24,0xFFFFFFFF-1);(root/'huge.zip').write_bytes(blob)
for fixture in pathlib.Path('Tests/ArchiveFixtures').glob('*.rar'): shutil.copy2(fixture,root/fixture.name)
