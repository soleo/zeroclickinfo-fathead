#!/usr/bin/env perl

use strict;
use warnings;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use Cwd qw( getcwd );
use DBI;
use File::Spec;
use IO::All;
use Mojo::DOM;
use Moo;
use Text::CSV_XS;
use URI;
use List::Util qw(first);
use List::MoreUtils qw(uniq);
use File::Find::Rule;

my %links;

has idris_doc_url => ( is => 'lazy' );
sub _build_idris_doc_url {
    'http://www.idris-lang.org/docs/current/';
}

has working_dir => ( is => 'lazy' );
sub _build_working_dir {
    getcwd;
}

has docs_dir => ( is => 'lazy' );
sub _build_docs_dir {
    return $_[0]->working_dir;
}

has pages => (
    is => 'ro',
    builder => 1,
);

my $base = 'download/docs/current/';

sub _build_pages {
    my ($self) = @_;
    my @pages = File::Find::Rule->file->name('*.html')->in($base);
    return [map { { path => $_, sub => $_ =~ s/\Q$base\E//r } } @pages];
}

has aliases => (
    is => 'ro',
    default => sub { {} },
);

has tsv => ( is => 'lazy' );
sub _build_tsv {
    my $dbh = DBI->connect ("dbi:CSV:", undef, undef, {
        f_encoding       => "UTF-8",
        csv_sep_char     => "\t",
        csv_class        => "Text::CSV_XS",
        csv_quote_char   => '',
        csv_escape_char  => '',
    });

    $dbh->do ( sprintf ( "CREATE TABLE output.txt (%s)",
        join ( ', ', map { "$_ CHAR" } ( qw/
            title type alias null1 categories null2 related null3
            links disambiguation image abstract sourceurl
        / ) )
    ) );

    return $dbh;
}

sub dom_for_file { Mojo::DOM->new( io($_[0])->all ); }

sub doc_fullpath {
    my ( $self, @parts ) = @_;
    File::Spec->catfile( $self->docs_dir, @parts );
}

sub doc_fullurl {
    my ( $self, $part ) = @_;
    URI->new(
        sprintf( '%s%s', $self->idris_doc_url, $part )
    )->canonical
}

sub normalize_dom_links {
    my ($url, $dom)  = @_;
    $dom->find('a')->map(sub {
        my $link = $_[0]->attr('href') or return;
        $_[0]->attr(href => URI->new_abs($link, $url)->as_string);
    });
}

sub insert {
    my ( $self, $data ) = @_;
    my %data = %$data;
    my @keys = keys %data;
    my $sql = sprintf( "INSERT INTO output.txt (%s) VALUES (%s)",
        join( ", ", @keys ),
        join( ", ", map { '?' } @keys ),
    );
    my @values = map { $data{$_} } @keys;
    $self->tsv->do( $sql, undef, @values );
}

sub select {
    my ($self, $what, $matching) = @_;
    my $sql = "SELECT * FROM output.txt WHERE $what = ?";
    return $self->tsv->selectrow_hashref($sql, undef, $matching);
}

sub alias {
    my ( $self, $new, $orig ) = @_;
    my @existing = @{ $self->aliases->{$new} // [] };
    $self->aliases->{$new} = [@existing, $orig];
}

sub insert_alias {
    my ($self, $new, $orig) = @_;
    $self->insert({
        title => $new,
        type  => 'R',
        alias => $orig,
    });
}

sub disambiguation {
    my ($self, $disambiguation) = @_;
    my @disambiguations = map {
        "*[[$_->{link}]], $_->{description}.";
    } @{ $disambiguation->{disambiguations} };
    my $dtext = join '\n', @disambiguations;
    $self->insert({
        type => 'D',
        title => $disambiguation->{title},
        disambiguation => $dtext,
    });
}

has articles => (
    is => 'ro',
    default => sub { {} },
);

sub article {
    my ($self, $article) = @_;
    my $title = $article->{title};
    warn "Duplicate article with title '$title' detected\n" and return
        if exists $self->articles->{$title};
    $links{$article->{url}} = $title;
    $self->articles->{$title} = $article;
}

sub entry {
    my ( $self, %article ) = @_;
    my ($title, $text, $url, $related) = @article{qw(title text url related)};
    my $related_text = '';
    # TODO: Find out how the related links should *actually* be formatted
    if (defined $related && @$related) {
        $related_text = join '', map { "[[$_]]" } @$related;
    }
    my $category_text = join '\n', @{$article{categories} || []};
    return warn "No text for '$title'" unless $text;
    $self->insert({
        abstract => $text,
        categories => $category_text,
        title => $title,
        type  => 'A',
        related  => $related_text,
        sourceurl => $url,
    });
}

#######################################################################
#                               Helpers                               #
#######################################################################

sub without_punct {
    $_[0] =~ s/\p{Punct}//gr;
}

sub make_aliases {
    my ($title, @aliases) = @_;
    my @valid_aliases = grep { $_ ne $title } @aliases;
    map { { new => $_, orig => $title } } @valid_aliases;
}

my $default_text_selector = 'p, pre';

# Produce the 'abstract' text content from the given Mojo::DOM spec.
sub text_from_selector {
    my ($dom, $spec) = @_;
    $spec //= $default_text_selector;
    return $dom->children($spec)->join();
}

sub ul_list_parser {
    my %options = (
        link => sub { $_[0]->find('a')->first->{name} },
        text => sub { text_from_selector($_[0]) },
        aliases => sub { () },
        uls => [],
        is_empty => sub { !($_[0]->find('p')->each) },
        redirect => sub { undef },
        disambiguation => sub { undef },
        related => sub { [] },
        categories => sub { [] },
        @_,
    );
    return sub {
        my ($self, $dom) = @_;
        my (@articles, @aliases, @uls, @disambiguations);
        if (my $s = $options{selector_main}) {
            @uls = ($dom->at($s)->following('ul')->first);
        } elsif (ref $options{uls} eq 'CODE') {
            @uls = $options{uls}->($dom);
        } else {
            @uls = @{$options{uls}};
        }
        foreach my $ul (@uls) {
            my @lis = $ul->children('li')->each;
            my @col = collate_li($options{is_empty}, @lis);
            foreach my $lit (@col) {
                my @items = @$lit;
                my $item = $items[$#items];

                my $link = $options{link}->($item);
                my $title = $options{title}->($item);
                my $text = $options{text}->($item);
                my @secondary_titles = map { $options{title}->($_) }
                    @items[0..$#items-1];
                my @titles = ($title, @secondary_titles);
                @aliases = (@aliases,
                    make_aliases($title, @secondary_titles),
                );
                foreach my $subt (@titles) {
                    @aliases = (@aliases,
                        make_aliases(
                            $title,
                            $options{aliases}->($item, $subt)
                        ),
                    );
                }
                my $article = {
                    title  => $title,
                    anchor => $link,
                    text   => $text,
                };
                my $categories = $options{categories}->($item, $article);
                $article->{categories} = $categories;
                my $related = $options{related}->($item, $article);
                $article->{related} = $related;
                if (my $disambiguation = $options{disambiguation}->($item, $article)) {
                    push @disambiguations, $disambiguation;
                    next;
                }
                if (my $redir = $options{redirect}->($item, $article)) {
                    @aliases = (@aliases, make_aliases($redir, $title));
                    next;
                }
                push @articles, $article;
            }
        }
        return {
            articles => \@articles,
            aliases  => \@aliases,
            disambiguations => \@disambiguations,
        };
    }
}

# If you have:
# - a
# - b
# - c
#   description for all
# Then use this to produce a list [a, b, c]
# (From a list of @li, this will produce a list of the above form for
# each group).
sub collate_li {
    my ($is_empty, @lis) = @_;
    my @res;
    my @r;
    foreach my $li (@lis) {
        push @r, $li;
        next if $is_empty->($li);
        push @res, [@r];
        @r = ();
    }
    return @res;
}

#######################################################################
#                       Normalize Parse Results                       #
#######################################################################

sub normalize_article {
    my ($article) = @_;
    my $text = $article->{text};
    $text =~ s/\n/ /g;
    return {
        %$article,
        text => $text,
    };
}

sub normalize_parse_result {
    my ($parsed) = @_;
    $parsed->{articles} = [
        map { normalize_article($_) } (@{$parsed->{articles}})
    ];
    return $parsed;
}

sub dom_for_parsing {
    my ($url, $page) = @_;
    my $dom = dom_for_file($page);
    normalize_dom_links($url, $dom);
    $dom->find('strong')->map('strip');
    $dom->find('code > a')->grep(sub { $_->parent->all_text eq $_->text })
        ->map( sub { $_->parent->strip });
    return $dom;
}

sub parse_dom {
    my ($self, $dom) = @_;
}

sub parse_page {
    my ( $self, $page ) = @_;
    my $fullpath = $self->doc_fullpath( $page->{path} );
    my $url = $self->doc_fullurl( $page->{sub} );
    my $parsed = $self->parse_dom(dom_for_parsing($url, $fullpath));
    $parsed = normalize_parse_result($parsed);
    for my $article ( @{ $parsed->{articles} } ) {
        my $anchored_url = $url;
        $anchored_url .= "#" . $article->{anchor} if $article->{anchor};

        $article->{url} = $anchored_url;
        $self->article($article);
    }

    for my $alias ( @{ $parsed->{aliases} } ) {
        $self->alias( $alias->{new}, $alias->{orig} );
    }
    for my $disambiguation ( @{ $parsed->{disambiguations} } ) {
        $self->disambiguation( $disambiguation );
    }
}

sub resolve_alias {
    my ($self, $title) = @_;
    my $to = $self->select(title => $title);
    while ($to->{type} eq 'R') {
        $to = $self->select(title => $to->{alias});
    }
    return $to;
}

sub resolve_aliases {
    my ($self) = @_;
    my %aliases = %{$self->aliases};
    while (my ($alias, $to) = each %aliases) {
        my @to = @$to;
        @to == 1 and $self->insert_alias($alias, $to[0]) and next;
        my @articles = map { $self->resolve_alias($_) } @to;
        scalar (uniq map { $_->{title} } @articles ) == 1
            and $self->insert_alias($alias, $to[0]) and next;
        $self->disambiguation({
            title => $alias,
            disambiguations => [map {
                { link => $_->{title}, description => $_->{abstract} },
            } @articles],
        });
    }
}

sub resolve_articles {
    my ($self) = @_;
    my %articles = %{$self->articles};
    foreach my $article (values %articles) {
        my $dom = Mojo::DOM->new->parse($article->{text});
        $dom->find('a[href]')->map(sub {
            my $link = $_->attr('href');
            if (my $point = $links{$link}) {
                $_->attr(href => "/?q=$point&ia=about");
            }
        });
        $article->{text} = $dom->to_string;
        $self->entry(%$article);
    }
}

sub parse {
    my ( $self ) = @_;
    foreach my $page (sort @{$self->pages}) {
        $self->parse_page($page);
    }

    $self->resolve_articles;
    $self->resolve_aliases;
}

main->new->parse;