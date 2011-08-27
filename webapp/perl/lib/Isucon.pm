package Isucon;

use strict;
use warnings;
use utf8;
use Devel::KYTProf;
use Kossy;
use DBI;
use JSON;
use Cache::Memcached::Fast;

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
    $self->{__mem} ||= Cache::Memcached::Fast->new({
        servers => [
            'xxx.xxx.xxx.xxx:11211',
            'xxx.xxx.xxx.xxx:11211',
        ]
    });
}

sub dbh {
    my $self = shift;
    my $config = $self->load_config;
    my $host = $config->{servers}{database}[0] || '127.0.0.1';
    DBI->connect_cached('dbi:mysql:isucon;host='.$host,'isuconapp','isunageruna',{
        RaiseError => 1,
        PrintError => 0,
        ShowErrorStatement => 1,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8 => 1
    });
}

filter 'recent_commented_articles' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;

        $c->stash->{recent_commented_articles} = $self->dbh->selectall_arrayref(
            'SELECT a.id, a.title FROM comment c INNER JOIN article a ON c.article = a.id 
            GROUP BY a.id ORDER BY MAX(c.id) DESC LIMIT 10',
            { Slice => {} });
        $app->($self,$c);
    }
};

get '/' => [qw/recent_commented_articles/] => sub {
    my ( $self, $c )  = @_;
    my $rows = $self->dbh->selectall_arrayref(
        'SELECT id,title,body,created_at FROM article ORDER BY id DESC LIMIT 10',
        { Slice => {} });
    $c->render('index.tx', { articles => $rows });
};

get '/article/:articleid' => [qw/recent_commented_articles/] => sub {
    my ( $self, $c )  = @_;
    my $article = $self->dbh->selectrow_hashref(
        'SELECT id,title,body,created_at FROM article WHERE id=?',
        {}, $c->args->{articleid});
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
    my $sth = $self->dbh->prepare('INSERT INTO article SET title = ?, body = ?');
    $sth->execute($c->req->param('title'), $c->req->param('body'));
    $c->redirect($c->req->uri_for('/'));
};

post '/comment/:articleid' => sub {
    my ( $self, $c )  = @_;

    my $sth = $self->dbh->prepare('INSERT INTO comment SET article = ?, name =?, body = ?');
    $sth->execute(
        $c->args->{articleid},
        $c->req->param('name'), 
        $c->req->param('body')
    );
    $c->redirect($c->req->uri_for('/article/'.$c->args->{articleid}));
};

1;

