#!/usr/bin/env perl -w
# vim: set sw=2 ts=2 sta et:

# GTrans: Automatic translation in Irssi using the Google Language API
# by Sven Ulland <svensven@gmail.com>

#TODO:
# what determines the value of isreliable? the api doc doesn't say.
# fix utf-8 handling.
#   + use this:   utf8::decode($text); Some problems?
#   + note in the doc that only utf-8 is supported
# DONE: error handling. How to print with activity?
# DONE: colorized? formatting string? how do other scripts do that?
#       (no use of mirc colors)
# DONE: outbound translation: configurable so that you can choose:
#   + DONE: a default outbound language without any writing overhead
#   + DONE: choose language in text:   en:jeg liker fisk  (prone to error)
#   + DONE: a command:   /gtrans en:jeg liker fisk
# outbound translation status (confidence) should be shown on the following line
# translate topic? notices, privmsgs, etc?
# debugging option
#   + DONE: general debugging
#   + consistent debugging levels. needs testing
# BIG FAT PRIVACY WARNING: Text is sent through google!
# DONE: decide to use " or '. Primarily "
# option to show original text
# DONE: code reuse (at least partially)
# handle max len (500 *bytes*). Is actually handled by the WGL API
# DONE: whitelist function, to specify which sources should be translated:
#   + DONE: whitelist channels
#   + WONTFIX: ^ how about servers/connections? same chan on many servers.
#   + DONE: whitelist nick/user masks
#   + DONE: whitelist all by specifying '*'
# DONE: handle signal 'message private' vs 'message public'?
# DONE: my languages, a list of languages that should not be modified.
# documentation
# check how to interact with logging
# doc: note that spelling is important
# signal_add vs signal_add_{first,last} ?
# link to http://code.google.com/apis/ajaxlanguage/documentation/reference.html#LangNameArray
# doc: note about fetching and using the WGL module with irssi.
# what are the sbitems, commands and modules for in %IRSSI?
# enable for /me too

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
  "dest"    => "",
);

sub dbg {
  my ($level, $msg) = @_;
  return unless ($level <= Irssi::settings_get_int("gtrans_debug"));

  my %dbgcol = (
    1 => "%G",
    2 => "%Y",
    3 => "%C",
    4 => "%M",
    5 => "%R",
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

sub event_privmsg {
  return unless Irssi::settings_get_bool("gtrans_input_auto");
  dbg(5, "event_privmsg() input: " . Dumper(\@_));

  # $data = "nick/#channel :text"
  my ($server, $data, $nick, $address) = @_;
  my ($target, $text) = split(/ :/, $data, 2);

  # Don't translate our own messages.
  return if $server->{nick} eq $nick;

  my $do_translation = 0;

  if ($target eq $server->{nick})
  {
    # Target is own nick, so we have a private message.
    # Check whether the source nick is in the whitelist.
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist_nicks"))) {
      $do_translation = 1 if ($nick eq $_);
      $do_translation = 1 if ($_ eq "*");
    }
  } else {
    # Target is channel, so we have a public message.
    # Check whether the channel is in the whitelist.
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist_channels"))) {
      $do_translation = 1 if ($target eq $_);
      $do_translation = 1 if ($_ eq "*");
    }
  }

  unless ($do_translation) {
    dbg(1, sprintf "Channel/nick \"$target\" is not whitelisted");
    return;
  }

  dbg(2, sprintf "event_privmsg() nick/channel is whitelisted");

  # Prepare arguments for language detection.
  utf8::decode($text);
  my %args = (
    "func" => sub { $service->detect(@_) },
    "text" => $text,
  );

  # Run language detection.
  my $result = wgl_process(%args);

  dbg(4, "event_privmsg() wgl_process() detect output: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "event_privmsg(): Language detection failed");
    err(sprintf "Language detection failed with code %s: %s",
        $result->code, $result->message);
    Irssi::signal_continue($server, $data, $nick, $address);
    return;
  }

  foreach (split(/ /, Irssi::settings_get_str("gtrans_my_lang"))) {
    $do_translation = 0 if($result->language eq $_);
  }

  unless ($do_translation) {
    dbg(2, "Incoming language \"$result->language\" matches " .
           "my lang(s). Not translating.");
    #Irssi::signal_continue($server, $data, $nick, $address);
    return;
  }

  dbg(1, sprintf "Detected language \"%s\", confidence %.3f",
                 $result->language, $result->confidence);

  my $confidence = $result->confidence;

  # Prepare arguments for translation.
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $text,
    #"src"  => $result->language, # not needed, apparently
    "dest" => (split(/ /,
        Irssi::settings_get_str("gtrans_my_lang")))[0]
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "event_privmsg() wgl_process() translate output: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "event_privmsg(): Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    #Irssi::signal_continue($server, $data, $nick, $address);
    return;
  }

  $text = sprintf "[%s:%.2f] %s",
      $result->language, $confidence, $result->translation;

  utf8::decode($text);

  $data = join(" :", $target, $text);

  # FIXME: More info about result?
  dbg(1, "Incoming translation successful");

  Irssi::signal_continue($server, $data, $nick, $address);
}

sub event_send {
  return unless (
      Irssi::settings_get_int("gtrans_output_auto") >= 0 and
      Irssi::settings_get_int("gtrans_output_auto") <= 2);

  my ($text, $server, $witem) = @_;
  dbg(5, "event_send() input: " . Dumper(\@_));

  # Determine destination language before doing translation.
  my $dest_lang;

  if (Irssi::settings_get_int("gtrans_output_auto") eq 1) {
    # Semiauto translation. Here we preprocess the text to determine
    # destination language. The WGL API cannot fetch the list of valid
    # languages, so we simply try to see if the language is valid.
    if ( $text =~ /^([a-z]{2}(-[a-z]{2})?):(.*)/i) {
      dbg(2, "event_send() dest_lang \"$1\", text \"$3\"");
      $dest_lang = $1;
      $text = $3;
    }
  }
  elsif (Irssi::settings_get_int("gtrans_output_auto") eq 2) {
    # Fully automated translation.
    $dest_lang = Irssi::settings_get_str("gtrans_output_auto_lang");
  }

  unless ($dest_lang and $text) {
    err("Empty destination language or text");
    Irssi::signal_continue($text, $server, $witem);
    return;
  }

  # Prepare arguments for translation.
  utf8::decode($text);
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $text,
    "dest" => $dest_lang
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "cmd_gtrans() wgl_process() output: " . Dumper(\$result));

  if ($result->error) {
    dbg(1, "cmd_gtrans(): Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    Irssi::signal_continue($text, $server, $witem);
    return;
  }

  if ($result->language ne $dest_lang) {
    $text = $result->translation;
    utf8::decode($text);
  }

  dbg(1, "Outbound auto-translation successful");

  Irssi::signal_continue($text, $server, $witem);
}

sub cmd_gtrans {
  my ($text, $server, $witem) = @_;
  dbg(5, "cmd_gtrans() input: " . Dumper(\@_));

  if ($text eq "help") {
    usage();
    return;
  }

  return unless ($witem and
                  ($witem->{type} eq "CHANNEL" or
                   $witem->{type} eq "QUERY"));

  # Determine destination language before doing translation.
  my $dest_lang;

  if ( $text =~ /^([a-z]{2}):(.*)/i) {
    dbg(2, "cmd_gtrans() dest_lang \"$1\", text \"$2\"");
    $dest_lang = $1;
    $text = $2;
  } else {
    dbg(2, "cmd_gtrans() syntax error");
  }

  unless ($dest_lang and $text) {
    err("Empty destination language or text");
    usage();
    return;
  }

  # Prepare arguments for translation.
  utf8::decode($text);
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $text,
    "dest" => $dest_lang
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "cmd_gtrans() wgl_process() output: " . Dumper(\$result));

  if ($result->error) {
    dbg(1, "cmd_gtrans(): Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  if ($result->language ne $dest_lang) {
    $text = $result->translation;
    utf8::decode($text);
  }

  dbg(1, "Outbound translation successful");

  $witem->command("MSG $witem->{name} $text");
}

print CLIENTCRAP "%W$IRSSI{name} loaded. " .
                 "Hints: %n/$IRSSI{commands} help";

Irssi::settings_add_bool("gtrans", "gtrans_input_auto",           1);
Irssi::settings_add_int ("gtrans", "gtrans_output_auto",          0);
Irssi::settings_add_str ("gtrans", "gtrans_output_auto_lang",  "fr");
Irssi::settings_add_str ("gtrans", "gtrans_my_lang",           "en");
Irssi::settings_add_int ("gtrans", "gtrans_debug",                0);
Irssi::settings_add_str ("gtrans", "gtrans_whitelist_channels",  "");
Irssi::settings_add_str ("gtrans", "gtrans_whitelist_nicks",     "");

Irssi::command_bind("gtrans", "cmd_gtrans");

Irssi::signal_add("event privmsg", "event_privmsg");
Irssi::signal_add("send text", "event_send");
