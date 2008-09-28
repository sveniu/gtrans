#!/usr/bin/env perl -w
# vim: set sw=2 ts=2 sta et:

# GTrans: Automatic translation in irssi using the Google Language API
# by Sven Ulland <svensven@gmail.com>

#TODO:
# what determines the value of isreliable? the api doc doesn't say.
# fix utf-8 handling.
#   + DONE: use this:   utf8::decode($text);
#   + note in the doc that only utf-8 is supported
# error handling. How to print with activity?
# colorized? formatting string? how do other scripts do that?
# DONE: outbound translation: configurable so that you can choose:
#   + DONE: a default outbound language without any writing overhead
#   + DONE: choose language in text:   en:jeg liker fisk  (prone to error)
#   + DONE: a command:   /gtrans en:jeg liker fisk
# outbound translation status (confidence) should be shown on the following line
# translate topic? notices, privmsgs, etc?
# DONE: debugging option
# BIG FAT PRIVACY WARNING: Text is sent through google!
# DONE: decide to use " or '. Primarily "
# option to show original text
# code reuse
# handle max len (500 *bytes*). Is actually handlede by the WGL API
# whitelist function, to specify which sources should be translated:
#   + whitelist channels
#   + ^ how about servers/connections? same chan on many servers.
#   + whitelist nick/user masks
#   + whitelist all by specifying 'all'
# DONE: my languages, a list of languages that should not be modified.
# documentation
# check how to interact with logging
# doc: note that spelling is important
# signal_add vs signal_add_{first,last} ?
# link to http://code.google.com/apis/ajaxlanguage/documentation/reference.html#LangNameArray
# doc: note about fetching and using the WGL module with irssi.
# what are the sbitems, commands and modules for in %IRSSI?

use strict;

use vars qw($VERSION %IRSSI);
use Irssi;
$VERSION = "0.0.0";
%IRSSI = (
    authors     => "Sven Ulland",
    contact     => "svensven\@gmail.com",
    name        => "GTrans",
    description => "Automatic translation via the Google Language API",
    license     => "GPLv2",
    url         => "http://scripts.irssi.org/",
    changed     => $VERSION,
    modules     => "WebService::Google::Language",
    sbitems     => "gtrans_sb",
    commands    => "gtrans"
);

use Data::Dumper qw(Dumper);
use WebService::Google::Language;

my $service = WebService::Google::Language->new(
  "referer" => "http://scripts.irssi.org/",
  "agent"   => "$IRSSI{name} $VERSION for Irssi",
  "timeout" => 5,
  "src"     => "",
  "dest"    => "en",
);

sub dbg {
  my ($level, $msg) = @_;
  return unless ($level <= Irssi::settings_get_int("gtrans_debug"));

  my %dbgcol = (
    1 => "%G",
    2 => "%Y",
    3 => "%M",
    4 => "%R",
  );

  print CLIENTCRAP "%W$IRSSI{name} " .
                   "%Bdebug%W($dbgcol{$level}$level%W)>%n $msg";
}

sub err {
  my $msg = shift;
  print CLIENTCRAP "%W$IRSSI{name} %Rerror%W>%n $msg";
}

sub inf {
  my $msg = shift;
  print CLIENTCRAP "%W$IRSSI{name} %Ginfo%W>%n $msg";
}

sub usage {
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n";
  print CLIENTCRAP "FIXME";
}

sub wgl_process {
  my %args = @_;
  dbg(5, "wgl_process(): input %args: " . Dumper(\%args));

  my $result = $args{func}(%args);
  dbg(4, "wgl_process() wgl_func() output: " . Dumper(\$result));

  my $ok = 1;
  if ($result->error) {
    err(sprintf "wgl_process() wgl_func() code %s: %s",
        $result->code,
        $result->message);
    $ok = 0;
  }

  return $result;
}

### sub event_privmsg {
###   return unless Irssi::settings_get_bool("gtrans_input_auto");
### 
###   # $data = "nick/#channel :text"
###   my ($server, $data, $nick, $address) = @_;
###   my ($target, $text) = split(/ :/, $data, 2);
###   return if $server->{nick} eq $nick;
### 
###   dbg(2, "event_privmsg() input \$text: $text");
### 
###   utf8::decode($text);
###   my %args = (
###     "text" => $text,
###     "dest" => (split(/ /,
###         Irssi::settings_get_str("gtrans_my_lang")))[0]
###   );
### 
###   my (
###       $confidence,
###       $reliable,
###       $translation,
###       $language,
###       $ok) = wgl_translate(%args);
###   utf8::decode($translation);
### 
###   my $translation_needed = 1;
###   foreach (split(/ /, Irssi::settings_get_str("gtrans_my_lang"))) {
###     if($language eq $_) {
###       $translation_needed = 0;
###     }
###   }
### 
###   if ($ok and $translation_needed) {
###     $text = sprintf "[%s:%.2f] %s",
###         $language,
###         $confidence,
###         $translation;
### 
###     $data = join(" :", $target, $text);
### 
###     dbg(1, sprintf "event_privmsg() translated from " .
###                    "%%B$language%%n with confidence " .
###                    "%s$confidence%%n", $reliable ? "%G" : "%Y");
###   }
### 
###   Irssi::signal_continue($server, $data, $nick, $address);
### }
### 
### sub event_send {
###   return unless (
###       Irssi::settings_get_int("gtrans_output_auto") >= 0 and
###       Irssi::settings_get_int("gtrans_output_auto") < 3);
### 
###   my ($text, $server, $witem) = @_;
### 
###   dbg(2, "event_send() input \$text: $text");
### 
###   my $dest_lang;
### 
###   if (Irssi::settings_get_int("gtrans_output_auto") eq 1) {
###     # Semiauto translation. Here we preprocess the text to determine
###     # destination language. The W:G:L API cannot fetch the list of
###     # valid languages, so we simply try to see if the language is
###     # valid.
###     if ( $text =~ /^([a-z]{2}(-[a-z]{2})?):(.*)/i) {
###       dbg(2, "event_send() dest_lang \"$1\", text \"$3\"");
###       $dest_lang = $1;
###       $text = $3;
###     }
###   }
###   elsif (Irssi::settings_get_int("gtrans_output_auto") eq 2) {
###     # Fully automated translation.
###     $dest_lang = Irssi::settings_get_str("gtrans_output_auto_lang");
###   }
### 
###   # FIXME: Verify this!
###   unless ($dest_lang and $text) {
###     # FIXME: Errorrrz
###     print "Empty destination language or text";
###     Irssi::signal_continue($text, $server, $witem);
###     return;
###   }
### 
###   utf8::decode($text);
###   my %args = (
###     "text" => $text,
###     "dest" => $dest_lang
###   );
###   my (
###       $confidence,
###       $reliable,
###       $translation,
###       $language,
###       $ok) = wgl_translate(%args);
### 
###   unless ($ok) {
###     print "gtrans DEBUG: Translation failed";
###     Irssi::signal_continue($text, $server, $witem);
###     return;
###   }
### 
###   if ($language ne $dest_lang) {
###     $text = sprintf "(%s:%.2f) %s",
###         #$reliable ? "good" : "bad",
###         $language,
###         $confidence,
###         $translation;
###     $text = $translation;
###     utf8::decode($text);
###     # FIXME: Informative
###     printf "Translation confidence: %.2f", $confidence;
###   }
### 
###   Irssi::signal_continue($text, $server, $witem);
### }

sub cmd_gtrans {
  my ($text, $server, $witem) = @_;
  dbg(5, "cmd_gtrans() input: " . Dumper(\@_));

  if ($text eq "help")
  {
    usage();
    Irssi::signal_stop();
    return;
  }

  my $dest_lang;

  return unless ($witem and
                  ($witem->{type} eq "CHANNEL" or
                   $witem->{type} eq "QUERY"));

  if ( $text =~ /^([a-z]{2}):(.*)/i) {
    dbg(2, "cmd_gtrans() dest_lang \"$1\", text \"$2\"");
    $dest_lang = $1;
    $text = $2;
  }
  else {
    dbg(2, "cmd_gtrans() syntax error");
  }

  unless ($dest_lang and $text) {
    err("Empty destination language or text");
    usage();
    Irssi::signal_stop();
    return;
  }

  utf8::decode($text);
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $text,
    "dest" => $dest_lang
  );
  my $result = wgl_process(%args);

  dbg(4, "cmd_gtrans() wgl_process() output: " . Dumper(\$result));

  if ($result->error) {
    dbg(1, "cmd_gtrans(): Translation failed");
    err(sprintf "Translation failure with code %s: %s",
        $result->code, $result->message);
    Irssi::signal_stop();
    return;
  }

  if ($result->language ne $dest_lang) {
    $text = $result->translation;
    utf8::decode($text);
  }

  dbg("Translation successful");

  Irssi::signal_continue($text, $server, $witem);
  $witem->command("MSG $witem->{name} $text");
}

print CLIENTCRAP "%W$IRSSI{name} loaded. " .
                 "Hints: %n/$IRSSI{commands} help";

Irssi::settings_add_bool("gtrans", "gtrans_input_auto",          1);
Irssi::settings_add_int ("gtrans", "gtrans_output_auto",         0);
Irssi::settings_add_str ("gtrans", "gtrans_output_auto_lang", "fr");
Irssi::settings_add_str ("gtrans", "gtrans_my_lang",          "en");
Irssi::settings_add_int ("gtrans", "gtrans_debug",               0);
#Irssi::settings_add_str ("gtrans", "gtrans_whitelist_channels",  "");
#Irssi::settings_add_str ("gtrans", "gtrans_whitelist_users",    "");

Irssi::command_bind("gtrans", "cmd_gtrans");

### Irssi::signal_add("event privmsg", "event_privmsg");
### Irssi::signal_add("send text", "event_send");

