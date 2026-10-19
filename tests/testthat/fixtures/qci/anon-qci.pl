#!/usr/bin/perl
# Length-preserving anonymiser for pdftotext -layout QCI extracts.
use strict; use warnings; use utf8;
binmode STDIN, ':encoding(UTF-8)'; binmode STDOUT, ':encoding(UTF-8)';
while (my $l = <STDIN>) {
  # Person names in the page-1 key:value grid (Contact, Sampler).
  if ($l =~ /^(\f?)(Contact|Sampler)(\s+:\s)(\S.*?)(\s{2,}|\n)/) {
    my ($ff, $k, $sep, $v, $tail) = ($1, $2, $3, $4, $5);
    if ($v ne '----') {
      my $rep = $k eq 'Contact' ? 'A. Contact' : 'A. Sampler';
      $rep .= ' ' x (length($v) - length($rep)) if length($v) > length($rep);
      die "name shorter than placeholder: $v" if length($rep) != length($v);
      substr($l, length($ff . $k . $sep), length($v)) = $rep;
    }
  }
  $l =~ s/BLUE MOUNTAINS/EXAMPLE CLIENT/g;
  $l =~ s/Lawson/Hamlet/g;
  $l =~ s/Attunga/Ridgely/g;  $l =~ s/attunga/ridgely/g;
  $l =~ s/Blackheath/Brookfield/g;
  $l =~ s/Katooma/Kingswy/g;
  $l =~ s/BWMF/SITA/g;
  $l =~ s/\bBH\.S/QH.S/g;
  $l =~ s/\bK\. Effluent/P. Effluent/g;
  print $l;
}
