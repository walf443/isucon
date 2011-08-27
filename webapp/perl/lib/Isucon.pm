package Isucon;

use strict;
use warnings;
use utf8;
use Devel::KYTProf;
use Kossy;
use DBI;
use JSON;
use Cache::Memcached::Fast;
use Compress::LZF;
use Data::MessagePack;

our $VERSION = 0.01;

my $config;

sub load_config {
    my $self = shift;
    $config ||= $self->_load_config;
}

sub _load_config {
    my $self = shift;
    open( my $fh, '<', $self->root_dir . '/../config/hosts.json') or die $!;
    local $/;
    my $json = <$fh>;
    close($fh);
    decode_json($json);    
}

sub mem {
    my $self = shift;
    $self->{__mem} ||= Cache::Memcached::Fast->new(+{
        servers => [
            'xxx.xxx.xxx.xxx:11211',
            'xxx.xxx.xxx.xxx:11211',
        ],
        connect_timeout => 0.2,
        io_timeout => 0.5,
        close_on_error => 1,
        compress_threshold => 100_000,
        compress_ratio => 0.9,
        compress_methods => [ sub { $_[1] = Compress::LZF::compress($_[0]) } ,
                              sub { $_[1] = Compress::LZF::decompress($_[0]) } ],
        max_failures => 3,
        failure_timeout => 2,
        ketama_points => 150,
        # nowait => 1,
        hash_namespace => 1,
        serialize_methods => [ sub { Data::MessagePack->pack($_[0]) }, sub { Data::MessagePack->unpack($_[0]) } ],
        utf8 => 1,
        max_size => 512 * 1024,
    });
}

sub dbh {
    my $self = shift;
    my $config = $self->load_config;
    my $host = $config->{servers}{database}[0] || '127.0.0.1';
    $self->{dbh} ||= DBI->connect_cached('dbi:mysql:isucon;host='.$host,'isuconapp','isunageruna',{
        RaiseError => 1,
        PrintError => 0,
        ShowErrorStatement => 1,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8 => 1
    });
}

sub set_recent_commented_articles {
    my $recent_commented_articles = $self->dbh->selectall_arrayref(
        'SELECT a.id, a.title FROM comment c INNER JOIN article a ON c.article = a.id 
        GROUP BY a.id ORDER BY MAX(c.id) DESC LIMIT 10',
        { Slice => {} });

    $self->mem->set($cache_key => $recent_commented_articles, 60);
    return $recent_commented_articles;
}

filter 'recent_commented_articles' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;

        my $cache_key = "recent_commented_articles";
        my $recent_commented_articles = $self->mem->get($cache_key);
        unless ( $recent_commented_articles ) {
            $recent_commented_articles = $self->set_recent_commented_articles;
        }

        $c->stash->{recent_commented_articles} = $recent_commented_articles;
        $app->($self,$c);
    }
};

get '/' => [qw/recent_commented_articles/] => sub {
    my ( $self, $c )  = @_;

    my $rows = $self->mem->get('top_articles');

    unless( $rows ) {
        $rows = $self->dbh->selectall_arrayref(
            'SELECT id,title,body,created_at FROM article ORDER BY id DESC LIMIT 10',
            { Slice => {} });
        $self->mem->set('top_articles',$rows,60);       
    }     
    $c->render('index.tx', { articles => $rows });
};

get '/article/:articleid' => [qw/recent_commented_articles/] => sub {
    my ( $self, $c )  = @_;
    
    my $article = $self->mem->get($c->args->{articleid});
   
    unless( $article ) {
        $article = $self->dbh->selectrow_hashref(
            'SELECT id,title,body,created_at FROM article WHERE id=?',
            {}, $c->args->{articleid});
        $self->mem->set($c->args->{articleid},$article,60);
    }      

    my $comments = $self->dbh->selectall_arrayref(
        'SELECT name,body,created_at FROM comment WHERE article=? ORDER BY id', 
        { Slice => {} }, $c->args->{articleid});

    $c->render('article.tx', { article => $article, comments => $comments });
};



get '/post' => [qw/recent_commented_articles/] => sub {
    my ( $self, $c )  = @_;
    $c->render('post.tx');
};

post '/post' => sub {
    my ( $self, $c )  = @_;
    $self->mem->delete_multi(qw/top_articles recent_commented_articles/);
    my $sth = $self->dbh->prepare('INSERT INTO article SET title = ?, body = ?');
    $sth->execute($c->req->param('title'), $c->req->param('body'));
    $c->redirect($c->req->uri_for('/'));
};

post '/comment/:articleid' => sub {
    my ( $self, $c )  = @_;

    $self->set_recent_commented_articles;
    my $sth = $self->dbh->prepare('INSERT INTO comment SET article = ?, name =?, body = ?');
    $sth->execute(
        $c->args->{articleid},
        $c->req->param('name'), 
        $c->req->param('body')
    );
    $c->redirect($c->req->uri_for('/article/'.$c->args->{articleid}));
};

1;

