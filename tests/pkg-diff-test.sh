#!/usr/bin/env roundup

describe "roundup(1) testing of pkg-diff"

basedir=$(dirname $BASH_SOURCE)/..
p=$basedir/pkg-diff.sh

# one-time prep
( cd specs && ./build.sh ) || exit 11

it_finds_text_diff()
{
    $p rpms/stringtext-1-[01].*.rpm
    ! $p rpms/stringtext-1-[02].*.rpm || return 1
}

it_prints_md5_or_sha256_diff()
{
    #= echo 123456|md5sum
    #= echo 123456|sha256sum
    $p rpms/stringtext-1-[02].*.rpm | grep \
        -e '^-/usr/share/doc.*/stringtext[^/]*/dir/string.txt f447b20a7fcbf53a5d5be013ea0b1' \
        -e '^-/usr/share/doc.*/stringtext[^/]*/dir/string.txt e150a1ec81e8e93e1eae2c3a77e66ec6dbd6a3b460f89c1d08aecf422ee401a0'
}

it_prints_text_diff()
{
    $p rpms/stringtext-1-[02].*.rpm | grep '^-123456$'
    $p rpms/stringtext-1-[02].*.rpm | grep '^+++ new//usr/share/doc.*/stringtext[^/]*/dir/string.txt'
}

it_finds_diff_even_with_identical_files()
{
    ! $p -a rpms/stringtext-1-1[01].*.rpm || return 1
    ! $p -a rpms/stringtext-1-1[02].*.rpm || return 1
    ! $p -a rpms/stringtext-1-1[12].*.rpm || return 1
}

it_reports_missing_files()
{
    ! $p -a rpms/stringtext-1-{2,12}.*.rpm || return 1
    $p -a rpms/stringtext-1-{2,12}.*.rpm | grep 'string2.txt differs'
}

it_reports_diffs_for_files_with_spaces()
{
    ! $p -a rpms/stringtext-1-10{0,1}.*.rpm || return 1
    $p -a rpms/stringtext-1-10{0,1}.*.rpm | grep '^-123456'
}

it_reports_differing_rpm_tags()
{
    ! $p -a rpms/stringtext-1-{1,3}.*.rpm || return 1
    $p -a rpms/stringtext-1-{1,3}.*.rpm | grep '^+bar 0'
}

it_produces_reproducible_diffs_2_12()
{
    #$p -a rpms/stringtext-1-{2,12}.*.rpm > reference/2-12.compare
    $p -a rpms/stringtext-1-{2,12}.*.rpm | diff -u10 reference/2-12.compare -
}
it_produces_reproducible_diffs_100_101()
{
    #$p -a rpms/stringtext-1-10{0,1}.*.rpm > reference/100-101.compare
    $p -a rpms/stringtext-1-10{0,1}.*.rpm | diff -u10 reference/100-101.compare -
}
