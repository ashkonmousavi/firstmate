#!/usr/bin/env bash
# fm-hold-reason-lib.sh - the one reversible encoding of a captain-hold reason.
#
# tasks-axi stores a hold reason as one markdown line inside a parenthesised tag,
# so its own `hold` refuses parentheses and line breaks. A decision reason is
# ordinary prose, so bin/fm-captain-hold.sh encodes the reason where it writes
# it and every reader that shows it decodes it again, instead of banning the
# characters. Stored reasons use fm-hold-v1: for base64-encoded UTF-8 text,
# or fm-hold-v2: for a base64-encoded JSON reason, release_on and episode.
# Unmarked reasons are plain text. Readers decode only
# the hold-reason field, once, and keep line breaks in quoted output strings.
#
# Source this file; it defines functions only.

# fm_hold_reason_encode <reason> [release-on]: print the storable form.
fm_hold_reason_encode() {
  printf '%s' "$1" | perl -MMIME::Base64=encode_base64 -MJSON::PP -MEncode=decode,FB_CROAK -e '
    local $/;
    my $reason = <STDIN>;
    if (length($ARGV[0] // "")) {
      my $record = {
        reason => decode("UTF-8", $reason, FB_CROAK),
        release_on => decode("UTF-8", $ARGV[0], FB_CROAK),
        episode => join("-", time, $$, int(rand(1e12)))
      };
      print "fm-hold-v2:", encode_base64(JSON::PP->new->utf8->canonical->encode($record), "");
    } else {
      print "fm-hold-v1:", encode_base64($reason, "");
    }
  ' -- "${2:-}"
}

# fm_hold_reason_decode_stream [toon|markdown|json]: decode marked reason fields.
fm_hold_reason_decode_stream() {
  perl -MJSON::PP -MMIME::Base64=encode_base64,decode_base64 -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $format = shift;
    my $json = JSON::PP->new->allow_nonref;
    sub decode_record {
      my ($value) = @_;
      return unless defined($value) && $value =~ /^fm-hold-v([12]):(.*)\z/s;
      my ($version, $payload) = ($1, $2);
      my $bytes = decode_base64($payload);
      return unless encode_base64($bytes, "") eq $payload;
      # Historical literals with valid base64 and UTF-8 remain indistinguishable
      # from encoded reasons; malformed payloads retain their stored text.
      my $decoded = eval { decode("UTF-8", $bytes, FB_CROAK) };
      return if $@;
      return { reason => $decoded } if $version == 1;
      my $record = eval { $json->decode($decoded) };
      return if $@ || ref($record) ne "HASH";
      for my $key (qw(reason release_on episode)) {
        return unless defined($record->{$key}) && !ref($record->{$key});
      }
      return unless length($record->{release_on}) && $record->{episode} =~ /^[0-9-]+\z/;
      $record->{binding} = $value;
      return $record;
    }
    sub decode_reason {
      my ($value) = @_;
      my $record = decode_record($value);
      return $record ? $record->{reason} : $value;
    }
    sub decode_field {
      my ($raw) = @_;
      my $value = $raw =~ /^"/ ? $json->decode($raw) : $raw;
      my $decoded = decode_reason($value);
      return $decoded eq $value ? $raw : $json->encode($decoded);
    }
    if ($format eq "json") {
      local $/;
      my $snapshot = $json->decode(<STDIN>);
      for my $record (@{$snapshot->{records}}) {
        $record->{hold_reason} = decode_reason($record->{hold_reason})
          if exists $record->{hold_reason};
      }
      print $json->encode($snapshot), "\n";
      exit;
    }
    my ($column, $task);
    while (my $line = <STDIN>) {
      if ($format eq "markdown") {
        $line =~ s{^([-*] .*\(hold:\s*)(fm-hold-v[12]:[A-Za-z0-9+/]*={0,2})(\).*)$}
          {$1 . decode_field($2) . $3}e;
      } elsif ($line =~ /^tasks\[\d+\]\{([^}]*)\}:\n?$/) {
        my @names = split /,/, $1;
        ($column) = grep { $names[$_] eq "hold_reason" } 0 .. $#names;
        $task = 0;
      } elsif (defined($column) && $line =~ /^  (.*)\n?$/) {
        my @fields = $1 =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
        $fields[$column] = decode_field($fields[$column]);
        $line = "  " . join(",", @fields) . "\n";
      } elsif ($task && $line =~ /^  hold_reason: (.*)\n?$/) {
        my $raw = $1;
        my $value = $raw =~ /^"/ ? $json->decode($raw) : $raw;
        my $record = decode_record($value);
        $line = "  hold_reason: " . decode_field($raw) . "\n";
        if ($record && exists($record->{release_on})) {
          $line .= "  hold_release_on: " . $json->encode($record->{release_on}) . "\n";
          $line .= "  hold_release_episode: " . $json->encode($record->{binding}) . "\n";
        }
      } elsif ($line !~ /^  /) {
        $column = undef;
        $task = $line eq "task:\n";
      }
      print $line;
    }
  ' "${1:-toon}"
}
