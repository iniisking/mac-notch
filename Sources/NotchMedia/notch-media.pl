#!/usr/bin/perl
# Loads libNotchMedia.dylib into /usr/bin/perl, which macOS still lets use the
# private MediaRemote framework, and runs one command.
#
#   /usr/bin/perl notch-media.pl /path/to/libNotchMedia.dylib stream|get|send N|seek SECONDS
use strict;
use warnings;
use DynaLoader;

my ($lib, $cmd, $arg) = @ARGV;
die "usage: notch-media.pl LIB stream|get|send N|seek SECONDS\n" unless defined $lib && defined $cmd;

my %symbols = (stream => 'notch_media_stream', get => 'notch_media_get', send => 'notch_media_send', seek => 'notch_media_seek');
my $symbol = $symbols{$cmd} or die "unknown command: $cmd\n";
$ENV{NOTCH_MEDIA_ARG} = defined $arg ? $arg : '';

my $handle = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib: " . DynaLoader::dl_error() . "\n";
my $fn = DynaLoader::dl_find_symbol($handle, $symbol) or die "symbol $symbol not found\n";
DynaLoader::dl_install_xsub('main::notch_run', $fn);
$| = 1;
notch_run();
