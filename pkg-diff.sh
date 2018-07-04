#! /bin/bash
#
# Copyright (c) 2009, 2010, 2011, 2012 SUSE Linux Product GmbH, Germany.
# Licensed under GPL v2, see COPYING file for details.
#
# Written by Michael Matz and Stephan Coolo
# Enhanced by Andreas Jaeger

FUNCTIONS=${0%/*}/functions.sh
: ${buildcompare_head:="head -n 200"}
nofilter=${buildcompare_nofilter}
sort=sort
[[ $nofilter ]] && sort=cat

check_all=
case $1 in
  -a | --check-all)
    check_all=1
    shift
esac

if test "$#" != 2; then
   echo "usage: $0 [-a|--check-all] old.rpm new.rpm"
   exit 1
fi

test -z $OBJDUMP && OBJDUMP=objdump

# Always clean up on exit
local_tmpdir=`mktemp -d`
if test -z "${local_tmpdir}"
then
  exit 1
fi
function _exit()
{
  chmod -R u+w "${local_tmpdir}"
  rm -rf "${local_tmpdir}"
}
trap _exit EXIT
# Let further mktemp refer to private tmpdir
export TMPDIR=$local_tmpdir

self_script=$(cd $(dirname $0); echo $(pwd)/$(basename $0))

source $FUNCTIONS

oldpkg=`readlink -f $1`
newpkg=`readlink -f $2`
rename_script=`mktemp`

if test ! -f "$oldpkg"; then
    echo "can't open $1"
    exit 1
fi

if test ! -f "$newpkg"; then
    echo "can't open $2"
    exit 1
fi

#usage unjar <file>
function unjar()
{
    local file
    file=$1

    if [[ $(type -p fastjar) ]]; then
        UNJAR=fastjar
    elif [[ $(type -p jar) ]]; then
        UNJAR=jar
    elif [[ $(type -p unzip) ]]; then
        UNJAR=unzip
    else
        echo "ERROR: jar, fastjar, or unzip is not installed (trying file $file)"
        exit 1
    fi

    case $UNJAR in
        jar|fastjar)
        # echo jar -xf $file
        ${UNJAR} -xf $file
        ;;
        unzip)
        unzip -oqq $file
        ;;
    esac
}

# list files in directory
#usage unjar_l <file>
function unjar_l()
{
    local file
    file=$1

    if [[ $(type -p fastjar) ]]; then
        UNJAR=fastjar
    elif [[ $(type -p jar) ]]; then
        UNJAR=jar
    elif [[ $(type -p unzip) ]]; then
        UNJAR=unzip
    else
        echo "ERROR: jar, fastjar, or unzip is not installed (trying file $file)"
        exit 1
    fi

    case $UNJAR in
        jar|fastjar)
        ${UNJAR} -tf $file
        ;;
        unzip)
        unzip -l $file
        ;;
    esac
}

filter_disasm()
{
   local file=$1
   [[ $nofilter ]] && return
   sed -i -e 's/^ *[0-9a-f]\+://' -e 's/\$0x[0-9a-f]\+/$something/' -e 's/callq *[0-9a-f]\+/callq /' -e 's/# *[0-9a-f]\+/#  /' -e 's/\(0x\)\?[0-9a-f]\+(/offset(/' -e 's/[0-9a-f]\+ </</' -e 's/^<\(.*\)>:/\1:/' -e 's/<\(.*\)+0x[0-9a-f]\+>/<\1 + ofs>/' ${file}
}

filter_zip_flist()
{
   local file=$1
   [[ $nofilter ]] && return
   #  10-05-2010 14:39
   sed -i -e "s, [0-9][0-9]-[0-9][0-9]-[0-9]\+ [0-9][0-9]:[0-9][0-9] , date ," $file
   # 2012-02-03 07:59
   sed -i -e "s, 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] , date ," $file
}

filter_xenefi() {
   # PE32+ executable (EFI application) x86-64 (stripped to external PDB), for MS Windows
   perl -e "open fh, '+<', '$f'; seek fh, 0x80 + 0x08, SEEK_SET; print fh 'time'; seek fh, 0x80 + 0x58, SEEK_SET; print fh 'chck';"
}

filter_pyc() {
   perl -e "open fh, '+<', '$f'; seek fh, 4, SEEK_SET; print fh '0000';"
}

filter_dvi() {
   # Opcodes 247: pre; i[1], num[4], den[4], mag[4], k[1], x[k]
   perl -e "
   my \$rec;
   open fh, '+<', '$f';
   my \$dummy = read fh, \$rec, 15;
   (\$pre, \$i, \$num, \$den, \$mag, \$k) = unpack('C2 N3 C', \$rec);
   seek fh, 15, SEEK_SET;
   while (\$k > 0) {
     print fh '0';
     \$k--;
   }
   "
}

filter_png() {
   convert "$f" +set date:create +set date:modify "${f}.$PPID.$$"
   mv -f "${f}.$PPID.$$" "${f}"
}

filter_emacs_lisp() {
   sed -i -e '
    s|^;;; .ompiled by abuild@.* on ... ... .. ..:..:.. ....|;;; compiled by abuild@buildhost on Wed Jul 01 00:00:00 2009|
    s|^;;; from file .*\.el|;;; from file /home/abuild/rpmbuild/BUILD/anthy-9100h/src-util/elc.8411/anthy-azik.el|
    s|^;;; emacs version .*|;;; emacs version 21.5  (beta34) "kale" XEmacs Lucid.|
    s|^;;; bytecomp version .*|;;; bytecomp version 2.28 XEmacs; 2009-08-09.|
    ' "$f"
}

filter_pdf() {
   # PDF files contain a unique ID, remove it
   # Format of the ID is:
   # /ID [<9ACE247A70CF9BEAFEE15E116259BD6D> <9ACE247A70CF9BEAFEE15E116259BD6D>]
   # with optional spaces. pdftex creates also:
   # /CreationDate (D:20120103083206Z)
   # /ModDate (D:20120103083206Z)
   # and possibly XML metadata as well
   sed -i \
        '/obj/,/endobj/{
           s%/ID \?\[ \?<[^>]\+> \?<[^>]\+> \?\]%/IDrandom%g;
           s%/CreationDate \?(D:[^)]*)%/CreationDate (D: XXX)%g;
           s%/ModDate \?(D:[^)]*)%/ModDate (D: XXX)%g;
           s%<pdf:CreationDate>[^<]*</pdf:CreationDate>%<pdf:CreationDate>XXX</pdf:CreationDate>%g;
           s%<pdf:ModDate>[^<]*</pdf:ModDate>%<pdf:ModDate>XXX</pdf:ModDate>%g;
           s%<xap:CreateDate>[^<]*</xap:CreateDate>%<xap:CreateDate>XXX</xap:CreateDate>%g;
           s%<xap:ModifyDate>[^<]*</xap:ModifyDate>%<xap:ModifyDate>XXX</xap:ModifyDate>%g;
           s%<xap:MetadataDate>[^<]*</xap:MetadataDate>%<xap:MetadataDate>XXX</xap:MetadataDate>%g;
        }' "$f"
}

filter_ps() {
   sed -i -e '
    /^%%CreationDate:[[:blank:]]/d
    /^%%Creator:[[:blank:]]groff[[:blank:]]version[[:blank:]]/d
    /^%DVIPSSource:[[:blank:]]/d
   ' "$f"
}

filter_mo() {
   sed -i -e "s,POT-Creation-Date: ....-..-.. ..:..+....,POT-Creation-Date: 1970-01-01 00:00+0000," "$f"
}

filter_linuxrc_config() {
   sed -i '/^InitrdID:/s@^.*@InitrdID: something@' "$f"
}

# call specified filter on old and new file
filter_generic()
{
   filtertype=$1
   [[ $nofilter ]] && return
   local f
   for f in "old/$file" "new/$file" ; do
      eval "filter_$filtertype $f"
   done
}


echo "Comparing `basename $oldpkg` to `basename $newpkg`"

case $oldpkg in
  *.rpm)
     cmp_rpm_meta "$rename_script" "$oldpkg" "$newpkg"
     RES=$?
     case $RES in
       0)
          echo "RPM meta information is identical"
          if test -z "$check_all"; then
             exit 0
          fi
          ;;
       1)
          echo "RPM meta information is different"
          if test -z "$check_all"; then
             exit 1
          fi
          ;;
       2)
          echo "RPM file checksum differs."
          RES=0
          ;;
       *)
          echo "Wrong exit code!"
          exit 1
          ;;
     esac
     ;;
esac

file1=`mktemp`
file2=`mktemp`

dir=`mktemp -d`
echo "Extracting packages"
unpackage $oldpkg $dir/old
unpackage $newpkg $dir/new

case $oldpkg in
  *.deb|*.ipk)
     adjust_controlfile $dir/old $dir/new
  ;;
esac

# files is set in cmp_rpm_meta for rpms, so if RES is empty we should assume
# it wasn't an rpm and pick all files for comparison.
if [ -z $RES ]; then
    oldfiles=`cd $dir/old; find . -type f`
    newfiles=`cd $dir/new; find . -type f`

    files=`echo -e "$oldfiles\n$newfiles" | sort -u`
fi

cd $dir
bash $rename_script

dfile=`mktemp`

diff_two_files()
{
  local offset length
  local po pn

  if test ! -e old/$file; then
    echo "Missing in old package: $file"
    return 1
  fi
  if test ! -e new/$file; then
    echo "Missing in new package: $file"
    return 1
  fi

  if cmp -b old/$file new/$file > $dfile ; then
    return 0
  fi
  if ! test -s $dfile ; then
    return 1
  fi

  offset=`sed 's@^.*differ: byte @@;s@,.*@@' < $dfile`
  echo "$file differs at offset '$offset' ($ftype)"
  po=`mktemp --dry-run $TMPDIR/old.XXX`
  pn=`mktemp --dry-run $TMPDIR/new.XXX`
  mkfifo -m 0600 $po
  mkfifo -m 0600 $pn
  offset=$(( ($offset >> 6) << 6 ))
  length=512
  hexdump -C -s $offset -n $length old/$file > $po &
  hexdump -C -s $offset -n $length new/$file > $pn &
  diff -u $po $pn | $buildcompare_head
  rm -f $po $pn
  return 1
}

trim_man_first_line()
{
    # Handles the first line if it is like:
    #.\" Automatically generated by Pod::Man 2.28 (Pod::Simple 3.28)
    #.\" DO NOT MODIFY THIS FILE!  It was generated by help2man 1.43.3.
    local f=$1
    [[ $nofilter ]] && return
    sed -i -e '1{
    s|^\.\\"[[:blank:]]\+Automatically[[:blank:]]generated[[:blank:]]by[[:blank:]]Pod::Man[[:blank:]].*|.\\" Overly verbose Pod::Man|
    s|^\.\\"[[:blank:]]\+DO[[:blank:]]NOT[[:blank:]]MODIFY[[:blank:]]THIS[[:blank:]]FILE![[:blank:]]\+It[[:blank:]]was[[:blank:]]generated[[:blank:]]by[[:blank:]]help2man[[:blank:]].*|.\\" Overly verbose help2man|
    }' $f
}

trim_man_TH()
{
    # Handles lines like:
    # .TH debhelper 7 "2010-02-27" "7.4.15" "Debhelper"
    # .TH DIRMNGR-CLIENT 1 2010-02-27 "Dirmngr 1.0.3" "GNU Privacy Guard"
    # .TH ccmake 1 "March 06, 2010" "ccmake 2.8.1-rc3"
    # .TH QEMU-IMG 1 "2010-03-14" " " " "
    # .TH kdecmake 1 "May 07, 2010" "cmake 2.8.1"
    # .TH "appender.h" 3 "12 May 2010" "Version 1.2.1" "log4c" \" -*- nroff -*-
    # .TH "appender.h" 3 "Tue Aug 31 2010" "Version 1.2.1" "log4c" \" -*- nroff -*-
    # .TH "OFFLINEIMAP" "1" "11 May 2010" "John Goerzen" "OfflineIMAP Manual"
    # .TH gv 3guile "13 May 2010"
    #.TH "GIT\-ARCHIMPORT" "1" "09/13/2010" "Git 1\&.7\&.1" "Git Manual"
    # .TH LDIRECTORD 8 "2010-10-20" "perl v5.12.2" "User Contributed Perl Documentation"
    # .TH ccmake 1 "February 05, 2012" "ccmake 2.8.7"
    # .TH "appender.h" 3 "Tue Aug 31 2010" "Version 1.2.1" "log4c" \" -*- nroff -*-
    # .TH ARCH "1" "September 2010" "GNU coreutils 8.5" "User Commands"
    # .TH "GCM-CALIBRATE" "1" "03 February 2012" "" ""
    #.TH Locale::Po4a::Xml.pm 3pm "2015-01-30" "Po4a Tools" "Po4a Tools"
    local f=$1
    [[ $nofilter ]] && return
    # (.TH   quoted section) (quoted_date)(*)
    sed -i -e 's|^\([[:blank:]]*\.TH[[:blank:]]\+"[^"]\+"[[:blank:]]\+[^[:blank:]]\+\)[[:blank:]]\+\("[^"]\+"\)\([[:blank:]]\+.*\)\?|\1 "qq2000-01-01"\3|' $f
    # (.TH unquoted section) (quoted_date)(*)
    sed -i -e 's|^\([[:blank:]]*\.TH[[:blank:]]\+[^"][^[:blank:]]\+[[:blank:]]\+[^[:blank:]]\+\)[[:blank:]]\+\("[^"]\+"\)\([[:blank:]]\+.*\)\?|\1 "uq2000-02-02"\3|' $f
    # (.TH   quoted section) (unquoted_date)(*)
    sed -i -e 's|^\([[:blank:]]*\.TH[[:blank:]]\+"[^"]\+"[[:blank:]]\+[^[:blank:]]\+\)[[:blank:]]\+\([^"][^[:blank:]]\+\)\([[:blank:]]\+.*\)\?|\1 qu2000-03-03\3|' $f
    # (.TH unquoted section) (unquoted_date)(*)
    sed -i -e 's|^\([[:blank:]]*\.TH[[:blank:]]\+[^"][^[:blank:]]\+[[:blank:]]\+[^[:blank:]]\+\)[[:blank:]]\+\([^"][^[:blank:]]\+\)\([[:blank:]]\+.*\)\?|\1 uu2000-04-04\3|' $f
}

strip_numbered_anchors()
{
  # Remove numbered anchors on Docbook / HTML files.
  #  <a id="idp270624" name=
  #  "idp270624"></a>
  # <a href="#ftn.id32751" class="footnote" id="id32751">
  # <a href="#id32751" class="para">
  # <a href="#tex">1 TeX</a>
  # <a href="dh-manual.html#id599116">
  # <a id="id479058">
  # <div id="ftn.id43927" class="footnote">
  # <div class="section" id="id46">

  [[ $nofilter ]] && return
  for f in old/$file new/$file; do
    sed -ie '
      1 {
      : N
        $ {
          s@\(<a[^>]\+id=\n\?"\)\(id[a-z0-9]\+\)\("[^>]*>\)@\1a_idN\3@g
          s@\(<a[^>]\+name=\n\?"\)\(id[a-z0-9]\+\)\("[^>]*>\)@\1a_nameN\3@g
          s@\(<a[^>]\+href="#\)\([^"]\+\)\("[^>]*>\)@\1href_anchor\3@g
          s@\(<a[^>]\+href="[^#]\+#\)\([^"]\+\)\("[^>]*>\)@\1href_anchor\3@g
          s@\(<div[^>]\+id="\)\([\.a-z0-9]\+\)\("[^>]*>\)@\1div_idN\3@g
        }
      N
      b N
      }' $f &
  done
  wait
}


check_compressed_file()
{
  local file=$1
  local ext=$2
  local tmpdir=`mktemp -d`
  local ftype
  local ret=0
  echo "$ext file with odd filename: $file"
  if test -n "$tmpdir"; then
    mkdir $tmpdir/{old,new}
    cp --parents --dereference old/$file $tmpdir/
    cp --parents --dereference new/$file $tmpdir/
    if pushd $tmpdir > /dev/null ; then
      case "$ext" in
        bz2)
          mv old/$file{,.bz2}
          mv new/$file{,.bz2}
          bzip2 -d old/$file.bz2 &
          bzip2 -d new/$file.bz2 &
          wait
          ;;
        gzip)
          mv old/$file{,.gz}
          mv new/$file{,.gz}
          gzip -d old/$file.gz &
          gzip -d new/$file.gz &
          wait
          ;;
        xz)
          mv old/$file{,.xz}
          mv new/$file{,.xz}
          xz -d old/$file.xz &
          xz -d new/$file.xz &
          wait
          ;;
      esac
      ftype=`/usr/bin/file old/$file | sed 's@^[^:]\+:[[:blank:]]*@@'`
      case $ftype in
        POSIX\ tar\ archive)
          echo "$ext content is: $ftype"
          mv old/$file{,.tar}
          mv new/$file{,.tar}
          if ! check_single_file ${file}.tar; then
            ret=1
          fi
          ;;
        ASCII\ cpio\ archive\ *)
          echo "$ext content is: $ftype"
          mv old/$file{,.cpio}
          mv new/$file{,.cpio}
          if ! check_single_file ${file}.cpio; then
            ret=1
          fi
          ;;
        fifo*pipe*)
          ftype_new="`/usr/bin/file new/$file | sed -e 's@^[^:]\+:[[:blank:]]*@@' -e 's@[[:blank:]]*$@@'`"
          if [ "$ftype_new" = "$ftype"  ]; then
            return 0
          fi
          return 1
          ;;
        *)
          echo "unhandled $ext content: $ftype"
          if ! diff_two_files; then
            ret=1
          fi
          ;;
      esac
      popd > /dev/null
    fi
    rm -rf "$tmpdir"
  fi
  return $ret
}

check_single_file()
{
  local file="$1"

  # If the two files are the same, return at once.
  if [ -f old/$file -a -f new/$file ]; then
    if cmp -s old/$file new/$file; then
      return 0
    fi
  fi
  case $file in
    *.spec)
       sed -i -e "s,Release:.*$release1,Release: @RELEASE@," old/$file
       sed -i -e "s,Release:.*$release2,Release: @RELEASE@," new/$file
       ;;
    *.exe.mdb|*.dll.mdb)
       # Just debug information, we can skip them
       echo "$file skipped as debug file."
       return 0
       ;;
    *.a)
       flist=`ar t new/$file`
       pwd=$PWD
       fdir=`dirname $file`
       cd old/$fdir
       ar x `basename $file`
       cd $pwd/new/$fdir
       ar x `basename $file`
       cd $pwd
       for f in $flist; do
          if ! check_single_file $fdir/$f; then
             return 1
          fi
       done
       return 0
       ;;
    *.cpio)
       flist=`cpio --quiet --list --force-local < "new/$file" | $sort`
       pwd=$PWD
       fdir=$file.extract.$PPID.$$
       mkdir old/$fdir new/$fdir
       cd old/$fdir
       cpio --quiet --extract --force-local < "../${file##*/}"
       cd $pwd/new/$fdir
       cpio --quiet --extract --force-local < "../${file##*/}"
       cd $pwd
       local ret=0
       for f in $flist; do
         if ! check_single_file $fdir/$f; then
           ret=1
           if test -z "$check_all"; then
             break
           fi
         fi
       done
       rm -rf old/$fdir new/$fdir
       return $ret
       ;;
    *.squashfs)
       flist=`unsquashfs -no-progress -ls -dest '' "new/$file" | grep -Ev '^(Parallel unsquashfs:|[0-9]+ inodes )' | $sort`
       fdir=$file.extract.$PPID.$$
       unsquashfs -no-progress -dest old/$fdir "old/$file"
       unsquashfs -no-progress -dest new/$fdir "new/$file"
       local ret=0
       for f in $flist; do
         if ! check_single_file $fdir/$f; then
           ret=1
           if test -z "$check_all"; then
             break
           fi
         fi
       done
       rm -rf old/$fdir new/$fdir
       return $ret
       ;;
    *.tar|*.tar.bz2|*.tar.gz|*.tgz|*.tbz2)
       flist=`tar tf new/$file`
       pwd=$PWD
       fdir=`dirname $file`
       cd old/$fdir
       tar xf `basename $file`
       cd $pwd/new/$fdir
       tar xf `basename $file`
       cd $pwd
       local ret=0
       for f in $flist; do
         if ! check_single_file $fdir/$f; then
           ret=1
           if test -z "$check_all"; then
             break
           fi
         fi
       done
       return $ret
       ;;
    *.zip|*.egg|*.jar|*.war)
       for dir in old new ; do
          (
             cd $dir
             unjar_l ./$file | $sort > flist
             filter_zip_flist flist
          )
       done
       if ! cmp -s old/flist new/flist; then
          echo "$file has different file list"
          diff -u old/flist new/flist
          return 1
       fi
       flist=`grep date new/flist | sed -e 's,.* date ,,'`
       pwd=$PWD
       fdir=`dirname $file`
       cd old/$fdir
       unjar `basename $file`
       cd $pwd/new/$fdir
       unjar `basename $file`
       cd $pwd
       local ret=0
       for f in $flist; do
         if test -f new/$fdir/$f && ! check_single_file $fdir/$f; then
           ret=1
           if test -z "$check_all"; then
             break
           fi
         fi
       done
       return $ret;;
     */xen*.efi)
        filter_generic xenefi
        ;;
     *.pyc|*.pyo)
        filter_generic pyc
        ;;
      *.dvi)
        filter_generic dvi
      ;;
     *.bz2)
        bunzip2 -c old/$file > old/${file/.bz2/}
        bunzip2 -c new/$file > new/${file/.bz2/}
        check_single_file ${file/.bz2/}
        return $?
        ;;
     *.gz)
        gunzip -c old/$file > old/${file/.gz/}
        gunzip -c new/$file > new/${file/.gz/}
        check_single_file ${file/.gz/}
        return $?
        ;;
     *.rpm)
	$self_script -a old/$file new/$file
        return $?
        ;;
     *png)
        # Try to remove timestamps, only if convert from ImageMagick is installed
        if [[ $(type -p convert) ]]; then
          filter_generic png
          if ! diff_two_files; then
            return 1
          fi
          return 0
        fi
        ;;
     /usr/share/locale/*/LC_MESSAGES/*.mo|/usr/share/locale-bundle/*/LC_MESSAGES/*.mo|/usr/share/vdr/locale/*/LC_MESSAGES/*.mo)
       filter_generic mo
       ;;
    */rdoc/files/*.html)
      # ruby documentation
      # <td>Mon Sep 20 19:02:43 +0000 2010</td>
      for f in old/$file new/$file; do
        sed -i -e 's%<td>[A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9]\+ [0-9]\+:[0-9]\+:[0-9]\+ +0000 201[0-9]</td>%<td>Mon Sep 20 19:02:43 +0000 2010</td>%g' $f
      done
      strip_numbered_anchors
    ;;
    /usr/share/doc/HTML/*/*/index.cache|/usr/share/doc//HTML/*/*/*/index.cache|\
    /usr/share/doc/kde/HTML/*/*/index.cache|/usr/share/doc/kde/HTML/*/*/*/index.cache|\
    /usr/share/gtk-doc/html/*/*.html|/usr/share/gtk-doc/html/*/*.devhelp2)
      # various kde and gtk packages
      strip_numbered_anchors
    ;;
    /usr/share/doc/packages/*/*.html|\
    /usr/share/doc/packages/*/*/*.html|\
    /usr/share/doc/*/html/*.html|\
    /usr/share/doc/kde/HTML/*/*/*.html)
      for f in old/$file new/$file; do
        sed -i -e '
          s|META NAME="Last-modified" CONTENT="[^"]\+"|META NAME="Last-modified" CONTENT="Thu Mar  3 10:32:44 2016"|
          s|<!-- Created on [^,]\+, [0-9]\+ [0-9]\+ by texi2html [0-9\.]\+ -->|<!-- Created on July, 14 2015 by texi2html 1.78 -->|
          s|<!-- Created on [^,]\+, [0-9]\+ by texi2html [0-9\.]\+$|<!-- Created on October 1, 2015 by texi2html 5.0|
          s|^<!-- Created on .*, 20.. by texi2html .\...|<!-- Created on August 7, 2009 by texi2html 1.82|
          s|This document was generated by <em>Autobuild</em> on <em>[^,]\+, [0-9]\+ [0-9]\+</em> using <a href="http://www.nongnu.org/texi2html/"><em>texi2html [0-9\.]\+</em></a>.|This document was generated by <em>Autobuild</em> on <em>July, 15 2015</em> using <a href="http://www.nongnu.org/texi2html/"><em>texi2html 1.78</em></a>.|
          s|^ *This document was generated by <em>Autobuild</em> on <em>.*, 20..</em> using <a href="http://www.nongnu.org/texi2html/"><em>texi2html .\...</em></a>.$|  This document was generated by <em>Autobuild</em> on <em>August 7, 2009</em> using <a href="http://www.nongnu.org/texi2html/"><em>texi2html 1.82</em></a>.|
          s|^ *This document was generated on <i>[a-zA-Z]\+ [0-9]\+, [0-9]\+</i> using <a href="http://www.nongnu.org/texi2html/"><i>texi2html [0-9\.]\+</i></a>.|  This document was generated on <i>October 1, 2015</i> using <a href="http://www.nongnu.org/texi2html/"><i>texi2html 5.0</i></a>.|
          s|Generated on ... ... [0-9]* [0-9]*:[0-9][0-9]:[0-9][0-9] 20[0-9][0-9] for |Generated on Mon May 10 20:45:00 2010 for |
          s|Generated on ... ... [0-9]* 20[0-9][0-9] [0-9]*:[0-9][0-9]:[0-9][0-9] for |Generated on Mon May 10 20:45:00 2010 for |
          ' $f
      done
      strip_numbered_anchors
    ;;
    /usr/*/javadoc/*.html)
      strip_numbered_anchors
      # There are more timestamps in html, so far we handle only some primitive versions.
      for f in old/$file new/$file; do
        # Javadoc:
        # <head>
        # <!-- Generated by javadoc (version 1.7.0_75) on Tue Feb 03 02:20:12 GMT 2015 -->
        # <!-- Generated by javadoc on Tue Feb 03 00:02:48 GMT 2015 -->
        # <!-- Generated by javadoc (1.8.0_72) on Thu Mar 03 12:50:28 GMT 2016 -->
        # <!-- Generated by javadoc (10-internal) on Wed Feb 07 06:33:41 GMT 2018 -->
        # <meta name="date" content="2015-02-03">
        # </head>
        sed -i -e '
          /^<head>/{
          : next
          n
          /^<\/head>/{
          b end_head
          }
          s/^<!-- Generated by javadoc ([0-9._]\+) on ... ... .. ..:..:.. \(GMT\|UTC\) .... -->/<!-- Generated by javadoX (1.8.0_72) on Thu Mar 03 12:50:28 GMT 2016 -->/
          t next
          s/^\(<!-- Generated by javadoc\) \((\(build\|version\) [0-9._]\+) on ... ... .. ..:..:.. \(GMT\|UTC\) ....\) \(-->\)/\1 some-date-removed-by-build-compare \5/
          t next
          s/^\(<!-- Generated by javadoc\) ([0-9._]\+-internal) on ... ... .. ..:..:.. \(GMT\|UTC\) .... \(-->\)/\1 some-date-removed-by-build-compare \3/
          t next
          s/^\(<!-- Generated by javadoc\) \(on ... ... .. ..:..:.. \(GMT\|UTC\) ....\) \(-->\)/\1 some-date-removed-by-build-compare \3/
          t next
          s/^<meta name="date" content="[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}">/<meta name="date" content="some-date-removed-by-build-compare">/
          b next
          }
          : end_head
          ' $f
        # Gjdoc HtmlDoclet:
        sed -i -e 's%Generated by Gjdoc HtmlDoclet [0-9,.]*, part of <a href="http://www.gnu.org/software/classpath/cp-tools/" title="" target="_top">GNU Classpath Tools</a>, on .*, 20.. [0-9]*:..:.. \(a\|p\)\.m\. GMT.%Generated by Gjdoc.%' $f
        sed -i -e 's%<!DOCTYPE html PUBLIC "-//gnu.org///DTD XHTML 1.1 plus Target 1.0//EN"\(.*\)GNU Classpath Tools</a>, on [A-Z][a-z]* [0-9]*, 20?? [0-9]*:??:?? \(a|p\)\.m\. GMT.</p>%<!DOCTYPE html PUBLIC "-//gnu.org///DTD XHTML 1.1 plus Target 1.0//EN"\1GNU Classpath Tools</a>, on January 1, 2009 0:00:00 a.m. GMT.</p>%' $f
        sed -i -e 's%<!DOCTYPE html PUBLIC "-//gnu.org///DTD\(.*GNU Classpath Tools</a>\), on [a-zA-Z]* [0-9][0-9], 20.. [0-9]*:..:.. \(a\|p\)\.m\. GMT.</p>%<!DOCTYPE html PUBLIC "-//gnu.org///DTD\1,on May 1, 2010 1:11:42 p.m. GMT.</p>%' $f
        # deprecated-list is randomly ordered, sort it for comparison
        case $f in
          */deprecated-list.html)
            [[ $nofilter ]] || sort -o $f $f
          ;;
        esac
      done
    ;;
    /usr/share/javadoc/gjdoc.properties|\
    /usr/share/javadoc/*/gjdoc.properties)
      for f in old/$file new/$file; do
        sed -i -e 's|^#[A-Z][a-z]\{2\} [A-Z][a-z]\{2\} [0-9]\{2\} ..:..:.. GMT 20..$|#Fri Jan 01 11:27:36 GMT 2009|' $f
      done
    ;;
     */fonts.scale|*/fonts.dir|*/encodings.dir)
       for f in old/$file new/$file; do
         # sort files before comparing
         [[ $nofilter ]] || sort -o $f $f
       done
       ;;
     /var/adm/perl-modules/*)
       for f in old/$file new/$file; do
         sed -i -e 's|^=head2 ... ... .. ..:..:.. ....: C<Module>|=head2 Wed Jul  1 00:00:00 2009: C<Module>|' $f
       done
       ;;
     /usr/share/man/man3/*3pm)
       for f in old/$file new/$file; do
         sed -i -e 's| 3 "20..-..-.." "perl v5....." "User Contributed Perl Documentation"$| 3 "2009-01-01" "perl v5.10.0" "User Contributed Perl Documentation"|' $f
         trim_man_TH $f
         trim_man_first_line $f
       done
       ;;
     */share/man/*|/usr/lib/texmf/doc/man/*/*)

       for f in old/$file new/$file; do
         trim_man_TH $f
         trim_man_first_line $f
         # generated by docbook xml:
         #.\"      Date: 09/13/2010
         sed -i -e 's|Date: [0-1][0-9]/[0-9][0-9]/201[0-9]|Date: 09/13/2010|' $f
       done
       ;;
     *.elc)
       filter_generic emacs_lisp
       ;;
     /var/lib/texmf/web2c/*/*fmt|\
     /var/lib/texmf/web2c/metafont/*.base|\
     /var/lib/texmf/web2c/metapost/*.mem)
       # binary dump of TeX and Metafont formats, we can ignore them for good
       echo "difference in $file ignored."
       return 0
       ;;
     */libtool)
       for f in old/$file new/$file; do
	  sed -i -e 's|^# Libtool was configured on host [A-Za-z0-9]*:$|# Libtool was configured on host x42:|' $f
       done
       ;;
     /etc/mail/*cf|/etc/sendmail.cf)
       # from sendmail package
       for f in old/$file new/$file; do
	  # - ##### built by abuild@build33 on Thu May 6 11:21:17 UTC 2010
	  sed -i -e 's|built by abuild@[a-z0-9]* on ... ... [0-9]* [0-9]*:[0-9][0-9]:[0-9][0-9] .* 20[0-9][0-9]|built by abuild@build42 on Thu May 6 11:21:17 UTC 2010|' $f
       done
       ;;
    */created.rid)
       # ruby documentation
       # file just contains a timestamp and nothing else, so ignore it
       echo "Ignore $file"
       return 0
       ;;
    */Linux*Env.Set.sh)
       # LibreOffice files, contains:
       # Generated on: Mon Apr 18 13:19:22 UTC 2011
       for f in old/$file new/$file; do
	 sed -i -e 's%^# Generated on:.*UTC 201[0-9] *$%# Generated on: Sometime%g' $f
       done
       ;;
    /usr/lib/libreoffice/solver/inc/*/deliver.log)
       # LibreOffice log file
      echo "Ignore $file"
      return 0
      ;;
    /var/adm/update-messages/*|/var/adm/update-scripts/*)
      # fetchmsttfonts embeds the release number in the update shell script.
      sed -i "s/${name_ver_rel_old_regex_l}/@NAME_VER_REL@/" old/$file
      sed -i "s/${name_ver_rel_new_regex_l}/@NAME_VER_REL@/" new/$file
      ;;
    *.ps)
      filter_generic ps
      ;;
    *pdf)
      filter_generic pdf
      ;;
      */linuxrc.config)
        echo "${file}"
        filter_generic linuxrc_config
      ;;
      */ld.so.cache|*/etc/machine-id)
        # packaged by libguestfs
        return 0
      ;;
      */etc/hosts)
        # packaged by libguestfs
        sed -i 's/^127.0.0.1[[:blank:]].*/127.0.0.1 hst/' "old/$file"
        sed -i 's/^127.0.0.1[[:blank:]].*/127.0.0.1 hst/' "new/$file"
      ;;
  esac

  ftype=`/usr/bin/file old/$file | sed -e 's@^[^:]\+:[[:blank:]]*@@' -e 's@[[:blank:]]*$@@'`
  case $ftype in
     PE32\ executable*Mono\/\.Net\ assembly*)
       echo "PE32 Mono/.Net assembly: $file"
       if [ -x /usr/bin/monodis ] ; then
         monodis old/$file 2>/dev/null|sed -e 's/GUID = {.*}/GUID = { 42 }/;'> ${file1}
         monodis new/$file 2>/dev/null|sed -e 's/GUID = {.*}/GUID = { 42 }/;'> ${file2}
         if ! cmp -s ${file1} ${file2}; then
           echo "$file differs ($ftype)"
           diff --speed-large-files -u ${file1} ${file2}
           return 1
         fi
       else
         echo "Cannot compare, no monodis installed"
         return 1
       fi
       ;;
    ELF*executable*|\
    ELF*[LM]SB\ relocatable*|\
    ELF*[LM]SB\ shared\ object*|\
    setuid\ ELF*[LM]SB\ shared\ object*|\
    ELF*[LM]SB\ pie\ executable*|\
    setuid\ ELF*[LM]SB\ pie\ executable*)
       $OBJDUMP -d --no-show-raw-insn old/$file > $file1
       ret=$?
       $OBJDUMP -d --no-show-raw-insn new/$file > $file2
       if test ${ret}$? != 00 ; then
         # objdump has no idea how to handle it
         if ! diff_two_files; then
           return 1
         fi
         return 0
       fi
       filter_disasm $file1
       filter_disasm $file2
       sed -i -e "s,old/,," $file1
       sed -i -e "s,new/,," $file2
       elfdiff=
       if ! diff --speed-large-files -u $file1 $file2 > $dfile; then
          echo "$file differs in assembler output"
          $buildcompare_head $dfile
          elfdiff="1"
       fi
       echo "" >$file1
       echo "" >$file2
       # Don't compare .build-id, .gnu_debuglink and .gnu_debugdata sections
       sections="$($OBJDUMP -s new/$file | grep "Contents of section .*:" | sed -r "s,.* (.*):,\1,g" | grep -v -e "\.build-id" -e "\.gnu_debuglink" -e "\.gnu_debugdata" | tr "\n" " ")"
       for section in $sections; do
          $OBJDUMP -s -j $section old/$file | sed "s,^old/,," > $file1
          $OBJDUMP -s -j $section new/$file | sed "s,^new/,," > $file2
          if ! diff -u $file1 $file2 > $dfile; then
             echo "$file differs in ELF section $section"
             $buildcompare_head $dfile
             elfdiff="1"
          fi
       done
       if test -z "$elfdiff"; then
          echo "$file: only difference was in build-id, gnu_debuglink or gnu_debugdata, GOOD."
          return 0
       fi
       return 1
       ;;
     *ASCII*|*text*)
       if ! cmp -s old/$file new/$file; then
         echo "$file differs ($ftype)"
         diff -u old/$file new/$file | $buildcompare_head
         return 1
       fi
       ;;
     directory|setuid\ directory|setuid,\ directory|sticky,\ directory)
       # tar might package directories - ignore them here
       return 0
       ;;
     bzip2\ compressed\ data*)
       if ! check_compressed_file "$file" "bz2"; then
           return 1
       fi
       ;;
     gzip\ compressed\ data*)
       if ! check_compressed_file "$file" "gzip"; then
           return 1
       fi
       ;;
     XZ\ compressed\ data*)
       if ! check_compressed_file "$file" "xz"; then
           return 1
       fi
       ;;
     POSIX\ tar\ archive)
          mv old/$file{,.tar}
          mv new/$file{,.tar}
          if ! check_single_file ${file}.tar; then
            return 1
          fi
       ;;
     cpio\ archive)
          mv old/$file{,.cpio}
          mv new/$file{,.cpio}
          if ! check_single_file ${file}.cpio; then
            return 1
          fi
     ;;
     Squashfs\ filesystem,*)
        echo "$file ($ftype)"
        mv old/$file{,.squashfs}
        mv new/$file{,.squashfs}
        if ! check_single_file ${file}.squashfs; then
          return 1
        fi
     ;;
     broken\ symbolic\ link\ to\ *|symbolic\ link\ to\ *)
       readlink "old/$file" > $file1
       readlink "new/$file" > $file2
       if ! diff -u $file1 $file2; then
         echo "symlink target for $file differs"
         return 1
       fi
       ;;
     block\ special\ *)
     ;;
     character\ special\ *)
     ;;
     *)
       if ! diff_two_files; then
           return 1
       fi
       ;;
  esac
  return 0
}

# We need /proc mounted for some tests, so check that it's mounted and
# complain if not.
PROC_MOUNTED=0
if [ ! -d /proc/self/ ]; then
  echo "/proc is not mounted"
  mount -orw -n -tproc none /proc
  PROC_MOUNTED=1
fi

# preserve cmp_rpm_meta result for check_all runs
ret=$RES
for file in $files; do
   if ! check_single_file $file; then
       ret=1
       if test -z "$check_all"; then
           break
       fi
   fi
done

if [ "$PROC_MOUNTED" -eq "1" ]; then
  echo "Unmounting proc"
  umount /proc
fi

rm $file1 $file2 $dfile $rename_script
rm -rf $dir
if test "$ret" = 0; then
     echo "Package content is identical"
fi
exit $ret
# vim: tw=666 ts=2 shiftwidth=2 et
