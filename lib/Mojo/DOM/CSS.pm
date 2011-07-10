package Mojo::DOM::CSS;
use Mojo::Base -base;

# Regex
my $CSS_ESCAPE_RE = qr/\\[^0-9a-fA-F]|\\[0-9a-fA-F]{1,6}/;
my $CSS_ATTR_RE   = qr/
  \[
  ((?:$CSS_ESCAPE_RE|\w)+)        # Key
  (?:
    (\W)?                         # Operator
    =
    (?:"((?:\\"|[^"])+)"|(\S+))   # Value
  )?
  \]
/x;
my $CSS_CLASS_ID_RE = qr/
  (?:
    (?:\.((?:\\\.|[^\#\.])+))   # Class
  |
    (?:\#((?:\\\#|[^\.\#])+))   # ID
  )
/x;
my $CSS_ELEMENT_RE      = qr/^((?:\\\.|\\\#|[^\.\#])+)/;
my $CSS_PSEUDO_CLASS_RE = qr/(?:\:([\w\-]+)(?:\(((?:\([^\)]+\)|[^\)])+)\))?)/;
my $CSS_TOKEN_RE        = qr/
  (\s*,\s*)?                                # Separator
  ((?:[^\[\\\:\s\,]|$CSS_ESCAPE_RE\s?)+)?   # Element
  ($CSS_PSEUDO_CLASS_RE*)?                  # Pseudoclass
  ((?:$CSS_ATTR_RE)*)?                      # Attributes
  (?:
  \s*
  ([\>\+\~])                                # Combinator
  )?
/x;

has 'tree';

# "Why can't she just drink herself happy like a normal person?"
sub select {
  my $self = shift;

  # Compile selector
  my $pattern = $self->_compile(shift);

  # Walk tree
  my @results;
  my $tree  = $self->tree;
  my @queue = ($tree);
  while (my $current = shift @queue) {
    my $type = $current->[0];

    # Root
    if ($type eq 'root') {

      # Fill queue
      unshift @queue, @$current[1 .. $#$current];
      next;
    }

    # Tag
    elsif ($type eq 'tag') {

      # Fill queue
      unshift @queue, @$current[4 .. $#$current];

      # Parts
      for my $part (@$pattern) {
        push(@results, $current) and last
          if $self->_element($current, $part, $tree);
      }
    }
  }

  return \@results;
}

sub _compile {
  my ($self, $css) = @_;

  # Tokenize
  my $pattern = [[]];
  while ($css =~ /$CSS_TOKEN_RE/g) {
    my $separator  = $1;
    my $element    = $2;
    my $pc         = $3;
    my $attributes = $6;
    my $combinator = $11;

    # Trash
    next
      unless $separator || $element || $pc || $attributes || $combinator;

    # New selector
    push @$pattern, [] if $separator;

    # Selector
    my $part = $pattern->[-1];
    push @$part, ['element'];
    my $selector = $part->[-1];

    # Element
    $element ||= '';
    my $tag = '*';
    $element =~ s/$CSS_ELEMENT_RE// and $tag = $self->_unescape($1);

    # Tag
    push @$selector, ['tag', $tag];

    # Class or ID
    while ($element =~ /$CSS_CLASS_ID_RE/g) {

      # Class
      push @$selector, ['attribute', 'class', $self->_regex('~', $1)]
        if defined $1;

      # ID
      push @$selector, ['attribute', 'id', $self->_regex('', $2)]
        if defined $2;
    }

    # Pseudo classes
    while ($pc =~ /$CSS_PSEUDO_CLASS_RE/g) {

      # "not"
      if ($1 eq 'not') {
        my $subpattern = $self->_compile($2)->[-1]->[-1];
        push @$selector, ['pseudoclass', 'not', $subpattern];
      }

      # Everything else
      else { push @$selector, ['pseudoclass', $1, $2] }
    }

    # Attributes
    while ($attributes =~ /$CSS_ATTR_RE/g) {
      my $key   = $self->_unescape($1);
      my $op    = $2 || '';
      my $value = $3;
      $value = $4 unless defined $3;

      push @$selector, ['attribute', $key, $self->_regex($op, $value)];
    }

    # Combinator
    push @$part, ['combinator', $combinator] if $combinator;
  }

  return $pattern;
}

sub _element {
  my ($self, $candidate, $selectors, $tree) = @_;

  # Match
  my @selectors  = reverse @$selectors;
  my $first      = 2;
  my $parentonly = 0;
  my ($current, $marker, $snapback, $siblings);
  for (my $i = 0; $i <= $#selectors; $i++) {
    my $selector = $selectors[$i];

    # Combinator
    $parentonly-- if $parentonly > 0;
    if ($selector->[0] eq 'combinator') {
      my $c = $selector->[1];

      # Parent only ">"
      if ($c eq '>') {
        $parentonly += 2;

        # Can't go back to the first
        unless ($first) {
          $marker   = $i       unless defined $marker;
          $snapback = $current unless $snapback;
        }
      }

      # Preceding siblings "~" and "+"
      elsif ($c eq '~' || $c eq '+') {
        my $parent = $current->[3];
        my $start = $parent->[0] eq 'root' ? 1 : 4;
        $siblings = [];

        # Siblings
        for my $i ($start .. $#$parent) {
          my $sibling = $parent->[$i];
          next unless $sibling->[0] eq 'tag';

          # Reached current
          if ($sibling eq $current) {
            @$siblings = ($siblings->[-1]) if $c eq '+';
            last;
          }
          push @$siblings, $sibling;
        }
      }

      # Move on
      next;
    }

    # Walk backwards
    while (1) {
      $first-- if $first > 0;

      # Next sibling
      if ($siblings) {

        # Last sibling
        unless ($current = shift @$siblings) {
          $siblings = undef;
          return;
        }
      }

      # Next parent
      else {
        return
          unless $current = $current ? $current->[3] : $candidate;

        # Don't search beyond the current tree
        return if $current eq $tree;
      }

      # Not a tag
      return if $current->[0] ne 'tag';

      # Compare part to element
      if ($self->_selector($selector, $current)) {
        $siblings = undef;
        last;
      }

      # First selector needs to match
      return if $first;

      # Parent only
      if ($parentonly) {

        # First parent needs to match
        return unless defined $marker;

        # Reset
        $i        = $marker - 2;
        $current  = $snapback;
        $snapback = undef;
        $marker   = undef;
        last;
      }
    }
  }

  return 1;
}

# "Rock stars... is there anything they don't know?"
sub _equation {
  my ($self, $equation) = @_;

  # "even"
  my $num = [1, 1];
  if ($equation =~ /^even$/i) { $num = [2, 2] }

  # "odd"
  elsif ($equation =~ /^odd$/i) { $num = [2, 1] }

  # Equation
  elsif ($equation =~ /(?:(\-?(?:\d+)?)?(n))?\s*\+?\s*(\-?\s*\d+)?\s*$/i) {
    $num->[0] = $1;
    $num->[0] = $2 ? 1 : 0 unless defined($num->[0]) && length($num->[0]);
    $num->[0] = -1 if $num->[0] eq '-';
    $num->[1] = $3 || 0;
    $num->[1] =~ s/\s+//g;
  }

  return $num;
}

sub _regex {
  my ($self, $op, $value) = @_;
  return unless $value;
  $value = quotemeta $self->_unescape($value);

  # "~=" (word)
  my $regex;
  if ($op eq '~') { $regex = qr/(?:^|.*\s+)$value(?:\s+.*|$)/ }

  # "*=" (contains)
  elsif ($op eq '*') { $regex = qr/$value/ }

  # "^=" (begins with)
  elsif ($op eq '^') { $regex = qr/^$value/ }

  # "$=" (ends with)
  elsif ($op eq '$') { $regex = qr/$value$/ }

  # Everything else
  else { $regex = qr/^$value$/ }

  return $regex;
}

# "All right, brain.
#  You don't like me and I don't like you,
#  but let's just do this and I can get back to killing you with beer."
sub _selector {
  my ($self, $selector, $current) = @_;

  # Selectors
  for my $c (@$selector[1 .. $#$selector]) {
    my $type = $c->[0];

    # Tag
    if ($type eq 'tag') {
      my $type = $c->[1];

      # Wildcard
      next if $type eq '*';

      # Type (ignore namespace prefix)
      next if $current->[1] =~ /(?:^|\:)$type$/;
    }

    # Attribute
    elsif ($type eq 'attribute') {
      my $key   = $c->[1];
      my $regex = $c->[2];
      my $attrs = $current->[2];

      # Find attributes (ignore namespace prefix)
      my $found = 0;
      for my $name (keys %$attrs) {
        if ($name =~ /\:?$key$/) {
          ++$found and last
            if !$regex || ($attrs->{$name} || '') =~ /$regex/;
        }
      }
      next if $found;
    }

    # Pseudo class
    elsif ($type eq 'pseudoclass') {
      my $class = lc $c->[1];
      my $args  = $c->[2];

      # "first-*"
      if ($class =~ /^first\-(?:(child)|of-type)$/) {
        $class = defined $1 ? 'nth-child' : 'nth-of-type';
        $args = 1;
      }

      # "last-*"
      elsif ($class =~ /^last\-(?:(child)|of-type)$/) {
        $class = defined $1 ? 'nth-last-child' : 'nth-last-of-type';
        $args = '-n+1';
      }

      # ":checked"
      if ($class eq 'checked') {
        my $attrs = $current->[2];
        next if ($attrs->{checked}  || '') eq 'checked';
        next if ($attrs->{selected} || '') eq 'selected';
      }

      # ":empty"
      elsif ($class eq 'empty') { next unless exists $current->[4] }

      # ":root"
      elsif ($class eq 'root') {
        if (my $parent = $current->[3]) {
          next if $parent->[0] eq 'root';
        }
      }

      # "not"
      elsif ($class eq 'not') {
        next unless $self->_selector($args, $current);
      }

      # "nth-*"
      elsif ($class =~ /^nth-/) {

        # Numbers
        $args = $c->[2] = $self->_equation($args)
          unless ref $args;

        # Siblings
        my $parent = $current->[3];
        my $start = $parent->[0] eq 'root' ? 1 : 4;
        my @siblings;
        my $type = $class =~ /of-type$/ ? $current->[1] : undef;
        for my $j ($start .. $#$parent) {
          my $sibling = $parent->[$j];
          next unless $sibling->[0] eq 'tag';
          next if defined $type && $type ne $sibling->[1];
          push @siblings, $sibling;
        }

        # Reverse
        @siblings = reverse @siblings if $class =~ /^nth-last/;

        # Find
        my $found = 0;
        for my $i (0 .. $#siblings) {
          my $result = $args->[0] * $i + $args->[1];
          next if $result < 1;
          last unless my $sibling = $siblings[$result - 1];
          if ($sibling eq $current) {
            $found = 1;
            last;
          }
        }
        next if $found;
      }

      # "only-*"
      elsif ($class =~ /^only-(?:child|(of-type))$/) {
        my $type = $1 ? $current->[1] : undef;

        # Siblings
        my $parent = $current->[3];
        my $start = $parent->[0] eq 'root' ? 1 : 4;
        for my $j ($start .. $#$parent) {
          my $sibling = $parent->[$j];
          next unless $sibling->[0] eq 'tag';
          next if $sibling eq $current;
          next if defined $type && $sibling->[1] ne $type;
          return if $sibling ne $current;
        }

        # No siblings
        next;
      }
    }

    return;
  }

  return 1;
}

sub _unescape {
  my ($self, $value) = @_;

  # Remove escaped newlines
  $value =~ s/\\\n//g;

  # Unescape unicode characters
  $value =~ s/\\([0-9a-fA-F]{1,6})\s?/pack('U', hex $1)/gex;

  # Remove backslash
  $value =~ s/\\//g;

  return $value;
}

1;
__END__

=head1 NAME

Mojo::DOM::CSS - CSS3 Selector Engine

=head1 SYNOPSIS

  use Mojo::DOM::CSS;

=head1 DESCRIPTION

L<Mojo::DOM::CSS> is the CSS3 selector engine used by L<Mojo::DOM>.
Note that this module is EXPERIMENTAL and might change without warning!

=head1 ATTRIBUTES

L<Mojo::DOM::CSS> implements the following attributes.

=head2 C<tree>

  my $tree = $css->tree;
  $css     = $css->tree(['root', ['text', 'lalala']]);

Document Object Model.

=head1 METHODS

L<Mojo::DOM::CSS> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 C<select>

  my $results = $css->select('head > title');

Run CSS3 selector against C<tree>.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut