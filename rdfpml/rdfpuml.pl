#!perl -w
# https://share.getty.edu/confluence/display/ITSLODV/rdfpuml
# https://share.getty.edu/confluence/pages/editpage.action?pageId=72024672

use strict;
use lib "./rdfpml/lib";
use Slurp; # https://metacpan.org/pod/Slurp
use RDF::Trine;
use RDF::Query;
use RDF::Prefixes::Curie;
use Smart::Comments;

my %PREFIXES =
  (
   crm => 'http://www.cidoc-crm.org/cidoc-crm/',
   crmx => 'http://purl.org/NET/cidoc-crm/ext#',
   frbroo => 'http://example.com/frbroo/',
   crmdig => 'http://www.ics.forth.gr/isl/CRMdig/',
   crmsci => 'http://www.ics.forth.gr/isl/crmsci/',
   puml => 'http://plantuml.com/ontology#',
   rdf => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
  );
my $PREFIXES_TURTLE = join "\n", map "\@prefix $_: <$PREFIXES{$_}>.", sort keys(%PREFIXES);
my $PREFIXES_SPARQL = join "\n", map "prefix $_: <$PREFIXES{$_}>", sort keys(%PREFIXES);;
my %HEAD = (none => "", tri => "|>", star => "*", o => "o");
my $HEAD_RE = join '|', keys %HEAD;
my %ARROW = (left => "←", right => "→", up => "↑", down => "↓");
my %OPPOSITE = (left => "right", right => "left", up => "down", down => "up");

my %dir; # $dir{$s}{$о} = left|right|up|down: direction of the relation between $s and $o
my %sanitized; # cona:700000166-thing -> cona_700000166_thing
my %predicate_arrow;

use constant {RE_CLASS=>0, RE_SUBJ_PROP=>1, RE_SHORTCUT_PROP=>2, RE_OBJ_PROP=>3};
my @RE =
  (
   [qw( rdf:Statement                 rdf:subject                    rdf:predicate                    rdf:object                 )],
   [qw( crm:E13_Attribute_Assignment  crm:P140_assigned_attribute_to crmx:property                    crm:P141_assigned          )],
   [qw( crm:E14_Condition_Assessment  crm:P34_concerned              crmx:property                    crm:P35_has_identified     )],
   [qw( crm:E15_Identifier_Assignment crm:P140_assigned_attribute_to crmx:property                    crm:P37_assigned           )],
   [qw( crm:E15_Identifier_Assignment crm:P140_assigned_attribute_to crmx:property                    crm:P38_deassigned         )],
   [qw( crm:E16_Measurement           crm:P39_measured               crmx:property                    crm:P40_observed_dimension )],
   [qw( crm:E17_Type_Assignment       crm:P41_classified             crmx:property                    crm:P42_assigned           )],
   [qw( frbroo:F52_Name_Use_Activity  frbroo:R63_named               crmx:property                    frbroo:R64_used_name       )],
   [qw( crmsci:S4_Observation         crmsci:O8_observed             crmsci:O9_observed_property_type crmsci:O16_observed_value  )],
  );

my $NOREL = # predicates that are not emitted as relations
  '^('.
  (join '|',
   map @$_[RE_SUBJ_PROP,RE_SHORTCUT_PROP,RE_OBJ_PROP], @RE # reification -> puml Assoc Class
  ).')$';

# E14,15,16,17 imply the shortuct prop, so RE_SHORTCUT_PROP is optional
my $RE = join " union\n", map <<SPARQL, @RE;
  {bind($_->[RE_SUBJ_PROP] as ?sp)
   bind($_->[RE_SHORTCUT_PROP] as ?pp)
   bind($_->[RE_OBJ_PROP] as ?op)
   ?re a $_->[RE_CLASS]; ?sp ?s; ?op ?o.
   optional {?re ?pp ?p}}
SPARQL

my $RE_SPARQL = <<"SPARQL";
$PREFIXES_SPARQL

select ?re ?sp ?pp ?op ?s ?p ?o {
$RE
filter not exists {?re a puml:NoReify}}
SPARQL
## $RE_SPARQL;

my $fname = shift or die "perl rdfpuml <file>: read <file>.ttl, write <file>.puml\n";
$fname =~ s{\.ttl$}{};

# Interesting, I don't need to worry about encoding. binmode(STDIN,":encoding(utf-8)");
my $file = slurp("$fname.ttl");
my $prefixes = slurp("./rdfpml/prefixes.ttl");

my $store = RDF::Trine::Store::Memory->new();
my $model = RDF::Trine::Model->new($store);
my $parser = RDF::Trine::Parser->new('turtle');
$parser->parse_into_model (undef, "$PREFIXES_TURTLE\n$prefixes\n$file", $model);
my $map = RDF::Prefixes::Curie->new ("$PREFIXES_TURTLE\n$prefixes");

# open (STDOUT, ">:encoding(utf-8)", "$fname.puml") or die "can't create $fname.puml: $!\n";
print <<'EOF';
@startuml
hide empty methods
hide empty attributes
hide circle
skinparam classAttributeIconSize 0
EOF

stereotypes();
replace_inlines();
collect_predicate_arrows();
# print STDERR $model->as_string; die;

for my $s ($model->subjects(undef,undef)) {
  my $s1 = puml_node($s);

  # types come first
  my @types = map puml_resource($_), $model->objects ($s, U("rdf:type"));
  my $noReify = grep m{puml:NoReify}, @types;
  my $types = join ", ", grep !m{puml:NoReify}, @types;
  print qq{$s1 : a $types\n} if $types;

  # relations
  for my $o ($model->objects ($s, undef, undef, type=>'resource')) {
    # collect all relations between the two nodes.
    # TODO: also collect inverse relations? Then be careful for reifications!
    my @predicates = grep !m{rdf:type}, map puml_predicate($_), $model->predicates ($s, $o);
    @predicates = grep !m{$NOREL}o, @predicates if !$noReify;
    next unless @predicates;
    my $arrow = find_predicate_arrow(@predicates);
    @predicates = grep !m{puml:}, @predicates;
    my $o1 = puml_node($o);
    $arrow = puml_arrow ($arrow, $s1, $o1);
    my $predicates = join '\n', @predicates; # each predicate label on new line, centered
    next if $s1 eq $o1;
    print qq{$s1 $arrow $o1 : $predicates\n}
  };

  # relations
  for my $o ($model->objects ($s, undef, undef, type=>'blank')) {
    # collect all relations between the two nodes.
    # TODO: also collect inverse relations? Then be careful for reifications!
    my @predicates = grep !m{rdf:type}, map puml_predicate($_), $model->predicates ($s, $o);
    @predicates = grep !m{$NOREL}o, @predicates if !$noReify;
    next unless @predicates;
    my $arrow = find_predicate_arrow(@predicates);
    @predicates = grep !m{puml:}, @predicates;
    my $o1 = puml_node($o);
    $arrow = puml_arrow ($arrow, $s1, $o1);
    my $predicates = join '\n', @predicates; # each predicate label on new line, centered
    next if $s1 eq $o1;
    print qq{$s1 $arrow $o1 : $predicates\n}
  };


  # literals (attributes, fields)
  my $it = $model->get_statements ($s, undef, undef);
  my %st;
  while (my $st = $it->next) {
    my $o = $st->object;
    next unless $o->is_literal;
    my $o1 = puml_literal($o);
    my $p = $st->predicate;
    my $p1 = puml_predicate($p);
    $st{$p1} ? ($st{$p1} .= ",\\n  $o1") : ($st{$p1} = $o1);
  }
  for my $p1(sort keys %st) {
    print qq{$s1 : $p1 $st{$p1}\n}
  }
}
reification();

print "\@enduml\n";

sub U {
  my $uri = $map->uri(shift);
  # print STDERR "$uri\n";
  RDF::Trine::Node::Resource->new ($uri)
}

sub replace_inlines {
  # ?inline a puml:Inline
  for my $inline ($model->subjects (U("rdf:type"), U("puml:Inline"))) {
    replace_inline($inline);
  }
  # ?prop a puml:InlineProperty
  for my $inlineProp ($model->subjects (U("rdf:type"), U("puml:InlineProperty"))) {
    # inline all Objects of inlineProp
    for my $inline ($model->objects (undef, $inlineProp, undef)) {
      replace_inline($inline);
    }
    $model->remove_statements (undef, U("rdf:type"), U("puml:InlineProperty"));
  }
  # For puml:NoReify nodes, inline the property pointed by SHORTCUT_PROP
  for my $sp (map U(@$_[RE_SHORTCUT_PROP]), @RE) {
    for my $noReify ($model->subjects (U("rdf:type"), U("puml:NoReify"))) {
      my $it = $model->get_statements ($noReify, $sp);
      while (my $st = $it->next) {
        next unless $st->object->is_resource; # $repl_st is returned by the iterator :-(
        # print STDERR $st->as_string;
        my $repl = $map->get_qname($st->object->uri_value);
        $repl = RDF::Trine::Node::Literal->new ($repl, undef, U("puml:noquote"));
        my $repl_st = RDF::Trine::Statement->new ($st->subject, $st->predicate, $repl);
        $model->remove_statement ($st);
        $model->add_statement ($repl_st);
      }
    }
  }
}

sub replace_inline {
  # replace given node with a literal having the url, and optionally its label
  my $inline = shift;
  my $repl = $map->get_qname($inline->uri_value);
  my ($label) = $model->objects ($inline, U("rdfs:label"));
  $repl .= " # " . $label->value if $label;
  $repl = RDF::Trine::Node::Literal->new ($repl, undef, U("puml:noquote")); # use as datatype
  my $it = $model->get_statements (undef, undef, $inline);
  while (my $st = $it->next) {
    my $repl_st = RDF::Trine::Statement->new ($st->subject, $st->predicate, $repl);
    $model->remove_statement ($st);
    $model->add_statement ($repl_st);
  }
  $model->remove_statements ($inline, undef, undef);
}

sub reification {
  my $query = RDF::Query->new($RE_SPARQL);
  my $it = $query->execute($model);
  while (my $row = $it->next) {
    $row->{o}->is_resource or die "can't reify literal: $row->{s} $row->{p} $row->{o}\n";
    # parallel relations are collected into one, so $p is ignored
    my $re = puml_node($row->{re}); # no blank node reifications, sorry
    my $sp = puml_predicate($row->{sp});
    my $pp = puml_predicate($row->{pp});
    my $op = puml_predicate($row->{op});
    my $s = puml_resource($row->{s}); # not sanitized
    my $p = puml_predicate($row->{p});

    my $o = puml_resource($row->{o}); # not sanitized
    $o =~ tr{()}{[]}; # round parens to square parens else PUML makes a method
    my $s1 = puml_node($row->{s}); # sanitized
    my $o1 = puml_node($row->{o}); # sanitized
    my $dir2 = $dir{$s1}{$o1} or die "$s->$o is in reification $re but not as direct relation\n";
    my $dir1 = $OPPOSITE{$dir2};
    my $arr1 = $ARROW{$dir1};
    my $arr2 = $ARROW{$dir2};
    # http://plantuml.com/classes.html#Association_classes
    # http://plantuml.sourceforge.net/qa/?qa=3788/set-direction-of-association-class
    my $orient = $dir1 =~ m(left|right) ? '..' : '.';
    my $dash   = $dir1 =~ m(left|right) ? ':' : '..';
    # http://plantuml.sourceforge.net/qa/?qa=4037/association-node-breaks-link-direction
    my $pair   = $dir2 =~ m{down|right} ? "$s1, $o1" : "$o1, $s1";
    print qq{($pair) $orient $re\n};
    # print prop names with decorative Unicode arrows
    print qq{$re : $arr1 $sp $s\n};
    print qq{$re : $dash $pp $p\n} if $pp;
    print qq{$re : $arr2 $op $o\n};
  }
}

sub puml_resource {
  my $node = shift;
  #print STDERR $node,"\n";
  return "" unless $node;
  my $meth = ($node->can("uri_value") or $node->can("blank_identifier"));
  $map->get_qname($node->$meth);
}

sub url_or_id {

}

sub puml_predicate {
  my $pred = puml_resource(shift);
  $pred eq "puml:label" ? "" : $pred
}

sub puml_node {
  my $node = shift;
  $node = puml_resource($node);
  my $sanitized = $sanitized{$node};
  return $sanitized if $sanitized;
  $sanitized = $node;
  $sanitized =~ s{[<>(): /.#=,%&?-]}{_}g;
  print qq{class $sanitized as "$node"\n};
  $sanitized{$node} = $sanitized
}

sub puml_literal {
  my $node = shift;
  my $val = $node->literal_value;
  my $dt = $node->literal_datatype;
  my $lang = $node->literal_value_language;
  $dt = $dt ? $map->get_qname($dt) : '';
  $dt = "puml:noquote" if
    $dt eq 'xsd:integer' && $val =~ /^[+-]?[0-9]+$/
    || $dt eq 'xsd:decimal' && $val =~ /^[+-]?[0-9]*\.[0-9]+$/
    || $dt eq 'xsd:double'  && $val =~ /^(?:(?:[+-]?[0-9]+\.[0-9]+)|(?:[+-]?\.[0-9]+)|(?:[+-]?[0-9]))[Ee][+-]?[0-9]+$/
    || $dt eq 'xsd:boolean' && $val =~ /^(true|false|0|1)/;
  $val =~ s{\n}{\\n}g; # newline to PUML newline
  $val =~ tr{()}{[]}; # round parens to square parens else PUML makes a method
  $val = qq{"$val"} unless $dt eq "puml:noquote";
  $val .= '@' . $lang if $lang;
  $val .= '^^' . $dt if $dt && $dt ne "puml:noquote";
  $val
}

sub puml_arrow {
  # puml:$dir-$head-$line
  # puml:(left|right|up|down)-(none|tri|star|o)-dashed
  local $_ = shift || '';
  my ($s,$o) = @_;
  my $dir = m{\b(left|right|up|down)} ? $1 : '';
  $dir{$s}{$o} = $dir || 'down';
  my $head = m{\b($HEAD_RE)\b}o ? $HEAD{$1} : '>';
  my $line = m{\b(dashed)\b} ? '.' : '-';
  "$line$dir$line$head"
}

sub collect_predicate_arrows {
  # eg "nif:oliaLink puml:arrow puml:up" causes $predicate_arrow{"nif:oliaLink"} = "puml:up"
  my $it = $model->get_statements (undef, U("puml:arrow"), undef);
  while (my $st = $it->next) {
    $predicate_arrow{$map->get_qname($st->subject->uri_value)} = $map->get_qname($st->object->uri_value)
  };
  $model->remove_statements (undef, U("puml:arrow"), undef);
}

sub find_predicate_arrow {
  # for each predicate in the list: return its specified arrow; or return itself if it's an arrow
  for (@_) {
    return $predicate_arrow{$_} if exists $predicate_arrow{$_};
    return $_ if m{puml:}
  }
  return undef
}

sub stereotypes {
  # eg fn:AnnotationSet puml:stereotype "(F)Frame"
  my $it = $model->get_statements (undef, U("puml:stereotype"), undef);
  while (my $st = $it->next) {
    my $class = $st->subject;
    my $stereotype = $st->object->literal_value;
    my $circle = $stereotype =~ m{\(.*\)};
    my $it1 = $model->get_statements (undef, U("rdf:type"), $class);
    while (my $st1 = $it1->next) {
      my $cls = puml_node($st1->subject);
      print "class $cls <<$stereotype>>\n";
      print "show $cls circle\n" if $circle;
    }
  };
  $model->remove_statements (undef, U("puml:stereotype"), undef);
}
