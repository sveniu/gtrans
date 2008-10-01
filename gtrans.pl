#!/usr/bin/env perl -w
# vim: set sw=2 ts=2 sta et:

# GTrans: Automatic translation in Irssi using the Google Language API
# by Sven Ulland <svensven@gmail.com>

#TODO:
# what determines the value of isreliable? the api doc doesn't say.
# fix utf-8 handling.
#   + use this:   utf8::decode($text); Some problems with html entities?
#   + note in the doc that only utf-8 is supported
# DONE: error handling. How to print with activity?
# DONE: colorized? formatting string? how do other scripts do that?
#       (no use of mirc colors)
# DONE: outbound translation: configurable so that you can choose:
#   + DONE: a default outbound language without any writing overhead
#   + DONE: choose language in text:   en:jeg liker fisk  (prone to error)
#   + DONE: a command:   /gtrans en:jeg liker fisk
# outbound translation status (confidence) should be shown on the following line
# DONE: translate notices, privmsgs, etc?
# translate topic
#   + DONE: translate incoming topic
#   + translate outgoing topic
#   + keep translated topic in topic bar with toggle
# debugging option
#   + DONE: general debugging
#   + consistent debugging levels. needs testing
# BIG FAT PRIVACY WARNING: Text is sent through google!
# DONE: decide to use " or '. Primarily "
# option to show original text
# DONE: code reuse (at least partially)
# handle max len (500 *bytes*). Is actually handled by the WGL API
# DONE: whitelist function, to specify which sources should be translated:
#   + DONE: whitelist channels and nicks
#   + WONTFIX: ^ how about servers/connections? same chan on many servers.
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
# DONE: enable for /me too
# doc: note lack of conn/srv differentiation
# DONE: test command to translate without sending anything over the wire.
# better code reuse. Lots of duplication now.
# DONE: /gtrans fo:bar is overridden by event_output_msg :(

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

my $glob_cmdpass = 0; # Urgh.

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
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n " .
                   "/$IRSSI{commands} [-t|--test] <lang>:<message>";
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n " .
                   "Example: /$IRSSI{commands} fr:this message " .
                   "will be translated to french and sent out";
  print CLIENTCRAP "%W$IRSSI{name} %Yusage%W>%n " .
                   "Example: /$IRSSI{commands} -t fi:this message " .
                   "will be translated to finnish, but *won't* be " .
                   "sent out";
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

sub event_input_msg {
  # signal "message public" parameters:
  # my ($server, $msg, $nick, $address, $target) = @_;
  #
  # signal "message private" parameters:
  # my ($server, $msg, $nick, $address) = @_;
  #
  # signal "message irc action" parameters:
  # my ($server, $msg, $nick, $address, $target) = @_;

  return unless Irssi::settings_get_bool("gtrans_input_auto");

  dbg(5, "event_input_msg() args: " . Dumper(\@_));

  my ($server, $msg, $nick, $address, $target) = @_;

  my $sig = Irssi::signal_get_emitted();
  dbg(3, "event_input_msg() signal type: \"$sig\"");

  my $do_translation = 0;

  if ($sig eq "message private" or
       ($sig eq "message irc action" and
        $target eq $server->{nick} )) {
    # Private message.
    # Check whether the source $nick is in the whitelist.
    dbg(3, "event_input_msg() Looking for nick \"$nick\" in " .
           "whitelist");
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist"))) {
      $do_translation = 1 if ($nick eq $_);
      $do_translation = 1 if ($_ eq "*");
    }
  } else {
    # Public message.
    # Check whether the $target is in the whitelist.
    dbg(3, "event_input_msg() Looking for channel \"$target\" in " .
           "whitelist");
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist"))) {
      $do_translation = 1 if ($target eq $_);
      $do_translation = 1 if ($_ eq "*");
    }
  }

  unless ($do_translation) {
    dbg(1, sprintf "Channel (\"$target\") or nick (\"$nick\") is " .
                   "not whitelisted");
    return;
  }

  dbg(2, sprintf "event_input_msg() Channel (\"$target\") or nick " .
                 "(\"$nick\") is whitelisted");

  # Prepare arguments for language detection.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->detect(@_) },
    "text" => $msg,
  );

  # Run language detection.
  my $result = wgl_process(%args);

  dbg(4, "event_input_msg() wgl_process() detect returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "event_input_msg(): Language detection failed");
    err(sprintf "Language detection failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # Don't translate my languages.
  foreach (split(/ /, Irssi::settings_get_str("gtrans_my_lang"))) {
    $do_translation = 0 if($result->language eq $_);
  }

  unless ($do_translation) {
    dbg(2, "event_input_msg() Incoming language " .
           "\"$result->language\" matches my lang(s). " .
           "Not translating.");
    return;
  }

  dbg(1, sprintf "Detected language \"%s\", confidence %.3f",
                 $result->language, $result->confidence);

  my $confidence = $result->confidence;

  # Prepare arguments for translation.
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
    "dest" => (split(/ /,
        Irssi::settings_get_str("gtrans_my_lang")))[0]
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "event_input_msg() wgl_process() translate returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # FIXME: Don't alter messages!
  $msg = sprintf "[%s:%.2f] %s",
      $result->language, $confidence, $result->translation;

  utf8::decode($msg);

  # FIXME: More info about result?
  dbg(1, "Incoming translation successful");

  Irssi::signal_continue($server, $msg, $nick, $address, $target);
}

sub event_output_msg {
  # signal "message own_public" parameters:
  # my ($server, $msg, $target) = @_;
  #
  # signal "message private" parameters:
  # my ($server, $msg, $target, $orig_target) = @_;
  #
  # signal "message irc own_action" parameters:
  # my ($server, $msg, $target) = @_;

  dbg(5, "event_output_msg() args: " . Dumper(\@_));
  my ($server, $msg, $target, $orig_target) = @_;

  if ($glob_cmdpass) {
    # Manual translation in gtrans_cmd() command is already done, so
    # don't do anything more. Yes, it should skip the whitelist, etc.
    dbg(4, "glob_cmdpass is set, so pass through unaltered");
    $glob_cmdpass = 0;
    return;
  }

  return unless (
      Irssi::settings_get_int("gtrans_output_auto") > 0 and
      Irssi::settings_get_int("gtrans_output_auto") <= 2);

  # Determine destination language before doing translation.
  my $dest_lang;

  if (Irssi::settings_get_int("gtrans_output_auto") eq 1) {
    # Semiauto translation. Here we preprocess the msg to determine
    # destination language. The WGL API cannot fetch the list of valid
    # languages, so we simply try to see if the language is valid.
    if ( $msg =~ /^([a-z]{2}(-[a-z]{2})?):(.*)/i) {
      dbg(2, "event_output_msg() dest_lang \"$1\", msg \"$3\"");
      $dest_lang = $1;
      $msg = $3;
    }
  }
  elsif (Irssi::settings_get_int("gtrans_output_auto") eq 2) {
    # Fully automated translation.
    # To avoid accidents, verify that $target is whitelisted.
    dbg(3, "event_output_msg() Looking for target \"$target\" in " .
           "whitelist");

    my $do_translation = 0;
    foreach (split(/ /,
        Irssi::settings_get_str("gtrans_whitelist"))) {
      $do_translation = 1 if ($target eq $_);
      $do_translation = 1 if ($_ eq "*");
    }

    unless ($do_translation) {
      dbg(1, sprintf "Target \"$target\" is not whitelisted");
      return;
    }

    dbg(2, sprintf "event_output_msg() Target \"$target\" " .
                   "is whitelisted");
    $dest_lang = Irssi::settings_get_str("gtrans_output_auto_lang");
  }

  unless ($dest_lang and $msg) {
    err("Empty destination language or message");
    return;
  }

  # Prepare arguments for translation.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
    "dest" => $dest_lang
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "event_output_msg() wgl_process() output: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "event_output_msg() Translation failed");
    err(sprintf "Translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  if ($result->language ne $dest_lang) {
    $msg = $result->translation;
    utf8::decode($msg);
  }

  dbg(1, "Outbound auto-translation successful");

  Irssi::signal_continue($server, $msg, $target, $orig_target);
}

sub event_topic {
  # signal "message own_public" parameters:
  # my ($server, $channel, $topic, $nick, $target) = @_;

  return unless Irssi::settings_get_bool("gtrans_topic_auto");

  dbg(5, "event_topic() args: " . Dumper(\@_));

  my ($server, $channel, $msg, $nick, $target) = @_;

  my $do_translation = 0;

  # Check whether $channel is in the whitelist.
  dbg(3, "event_topic() Looking for channel \"$channel\" in " .
         "whitelist");
  foreach (split(/ /,
      Irssi::settings_get_str("gtrans_whitelist"))) {
    $do_translation = 1 if ($channel eq $_);
    $do_translation = 1 if ($_ eq "*");
  }

  unless ($do_translation) {
    dbg(1, sprintf "Channel $channel is not whitelisted. " .
                   "Not translating topic");
    return;
  }

  dbg(2, sprintf "event_topic() Channel $channel is whitelisted");

  # Prepare arguments for language detection.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->detect(@_) },
    "text" => $msg,
  );

  # Run language detection.
  my $result = wgl_process(%args);

  dbg(4, "event_topic() wgl_process() detect returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "event_topic(): Language detection failed");
    err(sprintf "Language detection failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # Don't translate my languages.
  foreach (split(/ /, Irssi::settings_get_str("gtrans_my_lang"))) {
    $do_translation = 0 if($result->language eq $_);
  }

  unless ($do_translation) {
    dbg(2, "event_topic() Incoming language " .
           "\"$result->language\" matches my lang(s). " .
           "Not translating.");
    return;
  }

  dbg(1, sprintf "Detected language \"%s\", confidence %.3f",
                 $result->language, $result->confidence);

  my $confidence = $result->confidence;

  # Prepare arguments for translation.
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
    "dest" => (split(/ /,
        Irssi::settings_get_str("gtrans_my_lang")))[0]
  );

  # Run translation.
  my $result = wgl_process(%args);

  dbg(4, "event_topic() wgl_process() translate returned: " .
         Dumper(\$result));

  if ($result->error) {
    dbg(1, "Topic translation failed");
    err(sprintf "Topic translation failed with code %s: %s",
        $result->code, $result->message);
    return;
  }

  # FIXME: Don't alter messages!
  $msg = sprintf "[%s:%.2f] %s",
      $result->language, $confidence, $result->translation;

  utf8::decode($msg);

  # FIXME: More info about result?
  dbg(1, "Incoming topic translation successful");

  Irssi::signal_continue($server, $channel, $msg, $nick, $target);
}

sub cmd_gtrans {
  my ($msg, $server, $witem) = @_;
  dbg(5, "cmd_gtrans() input: " . Dumper(\@_));

  if ($msg =~ /^(|help|-h|--help|-t|--test)$/) {
    usage();
    return;
  }

  my $testing_mode = 0;
  if ($msg =~ /^(-t|--test) /) {
    $testing_mode = 1;
    $msg =~ s/^(-t|--test) //;
  }

  return unless ($testing_mode or
                    ($witem and
                        ($witem->{type} eq "CHANNEL" or
                         $witem->{type} eq "QUERY")));

  # Determine destination language before doing translation.
  my $dest_lang;

  # FIXME: What about languages on the form "xx-yy"?
  if ( $msg =~ /^([a-z]{2}):(.*)/i) {
    dbg(2, "cmd_gtrans() dest_lang \"$1\", msg \"$2\"");
    $dest_lang = $1;
    $msg = $2;
  } else {
    dbg(2, "cmd_gtrans() syntax error");
  }

  unless ($dest_lang and $msg) {
    err("Empty destination language or msg");
    usage();
    return;
  }

  # Prepare arguments for translation.
  utf8::decode($msg);
  my %args = (
    "func" => sub { $service->translate(@_) },
    "text" => $msg,
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
    $msg = $result->translation;
    utf8::decode($msg);
  }

  dbg(1, "Outbound translation successful");

  if ($testing_mode) {
    $witem = Irssi::active_win();
    $witem->print("%GGTrans testing:%n $msg", MSGLEVEL_CLIENTCRAP);
  } else {
    $glob_cmdpass = 1; # Skip next translation in event_output_msg()
    $witem->command("MSG $witem->{name} $msg");
  }
}

print CLIENTCRAP "%W$IRSSI{name} loaded. " .
                 "Hints: %n/$IRSSI{commands} help";

# Register gtrans settings.
Irssi::settings_add_bool("gtrans", "gtrans_input_auto",          1);
Irssi::settings_add_bool("gtrans", "gtrans_topic_auto",          0);
Irssi::settings_add_int ("gtrans", "gtrans_output_auto",         0);
Irssi::settings_add_str ("gtrans", "gtrans_output_auto_lang", "fr");
Irssi::settings_add_str ("gtrans", "gtrans_my_lang",          "en");
Irssi::settings_add_int ("gtrans", "gtrans_debug",               0);
Irssi::settings_add_str ("gtrans", "gtrans_whitelist",          "");

# Register /gtrans command.
Irssi::command_bind("gtrans",                    "cmd_gtrans");

# Register events for incoming messages/actions.
Irssi::signal_add("message public",         "event_input_msg");
Irssi::signal_add("message private",        "event_input_msg");
Irssi::signal_add("message irc action",     "event_input_msg");
Irssi::signal_add("message irc notice",     "event_input_msg");

# Register events for outgoing messages/actions.
Irssi::signal_add("message own_public",     "event_output_msg");
Irssi::signal_add("message own_private",    "event_output_msg");
Irssi::signal_add("message irc own_action", "event_output_msg");
Irssi::signal_add("message irc own_notice", "event_output_msg");

# Register events that need special handling.
Irssi::signal_add("message topic",          "event_topic");
