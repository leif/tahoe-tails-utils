#!/bin/bash
web_port=7657 # BUG: need to figure out how tails is opening this port. If
              # you're not using Tails, you might want to uncomment the line
              # below and use the default web port instead:
#web_port=3456
intro_furl=pb://ifwpslh5f4jx2s3tzkkj4cyymrcxcunz@bvkb2rnvjbep4sjz.onion:58086/introducer
grid_news_read_cap=URI:DIR2-RO:j7flrry23hfiix55xdakehvayy:pn7wdmukxulpwxc3khdwqcmahdusgvfljjt4gx5oe4z35cyxngga
git_url=https://github.com/leif/tahoe-lafs
git_branch=truckee
deps_sha1="bfc0798f5f332ad5edb6d259391e4bb917283c17"
depstgz=tahoe-deps.tar.gz
depsurl=https://tahoe-lafs.org/source/tahoe-lafs/deps/$depstgz
main() {
    if [ "$1" == "" ]; then
        echo "usage: $0 TARGET_DIR"
        echo
        echo "TARGET_DIR is where Tahoe source and config will be installed."
        echo "You will need ~200M free to build. If using Tails, it is"
        echo "recommended to specify your Persistent directory or something"
        echo "under it."
        echo
        exit 1
    fi
    set -e
    cd $1
    clear
    cat <<EOF
This is a hacky (but hopefully idempotent) script that "securely" (relying on
HTTPS) bootstraps a Tahoe-LAFS client node and connects it to a Tor Hidden
Service-based grid. It has been tested on Tails 0.19 but should work on any
recent debian system with tor and torsocks installed.

Quickstart instructions for Tails users:
 1. Create a persistent volume (Applications->Tails->Configure persistent
    volume) which saves (at least) "Personal Data", "APT Packages", and "APT
    Lists". Reboot Tails to activate it.
 2. Save this script into your Persistent directory (~/Persistent or something
    like /live/persistence/sdb2_unlocked/Persistent if Tails forgot to make the
    symlink, which it sometimes does).
 3. If you have 1GB or less RAM, close Iceweasel and any other applications so
    that there will be enough memory for the build process.
 4. Run this script with the path to your Persistent directory
 5. Your new tahoe write capability should be displayed.

On subsequent Tails sessions with the same persistent volume, only step 4 is
necessary and it will be much faster because nothing is downloaded or rebuilt.

EOF
    echo -n "(enter to continue, or ctrl-c to abort)"
    read
    clear
    cat <<EOF
If you write data to your directory which you want to keep, be sure not to lose
the writecap (it is printed by "tahoe list-aliases" and is saved in
~/Persistent/tahoe-lafs/tahoe-client/private/aliases).

Also, please consider operating a storage server on the grid for others to use!

BUG: I haven't figured out how tails is allowing Iceweasel to access certain
localhost ports, so I'm borrowing one ($web_port) from i2p. So, this won't
work while you're also running i2p.

(enter to begin, or ctrl-c to abort)
EOF
    read
    set -x
    boostrap_tahoe
    [ "$(dpkg -l|egrep 'ii  (tor |torsocks)'|wc -l)" == 2 ] || \
    sudo apt-get install tor torsocks
    start_new_client $(pwd)/tahoe-client $intro_furl $web_port
    set +x
    wait_for_n_servers 5 $web_port
    echo "Creating 'tahoe:' alias"
    tahoe create-alias tahoe || true
    echo Adding link to grid-news in your tahoe directory
    tahoe ln $grid_news_read_cap grid-news 2>&1 | grep -v "Error: You can't overwrite a directory with a file" ||true
    echo
    echo "This is your 'tahoe:' write capability:"
    tahoe list-aliases
    echo "(you might want to save that somewhere else)"
    echo
    echo "You can view the grid-news page with 'tahoe webopen grid-news/Latest/index.html'"
    echo
    echo "Running 'tahoe webopen tahoe:' now. Welcome to The Onion Grid!"
    tahoe webopen tahoe:
}

boostrap_tahoe(){
    # this function is intended to idempotently and securely (relying on https)
    # install tahoe. everything will be contained within the tahoe-lafs
    # directory except for a symlink which is placed in /usr/local/bin
    [ "$(dpkg -l|egrep 'ii  (build-essential|python-dev)'|wc -l)" == 2 ] || \
    sudo apt-get install build-essential python-dev
    [ -d tahoe-lafs ] || \
    usewithtor git clone $git_url
    pushd tahoe-lafs
    git checkout $git_branch
    if [ ! -d tahoe-deps ]; then 
        [ -f "$depstgz" ] && [ "$(sha1sum $depstgz|cut -f1 -d' ')" == "$deps_sha1" ] || wget -O $depstgz $depsurl
        [ "$(sha1sum $depstgz|cut -f1 -d' ')" != "$deps_sha1" ] && echo $depstgz sha1sum is wrong && exit
        tar xf $depstgz
    fi
    # note: this step will needlessly try to connect to the internet, but on
    # Tails it will be unable to connect due to firewall rules. See
    # https://tahoe-lafs.org/trac/tahoe-lafs/ticket/2055 for more information.
    export http_proxy=""
    export HTTP_PROXY=""
    export https_proxy=""
    export HTTPS_PROXY=""
    python setup.py build
    [ -L /usr/local/bin/tahoe ] || sudo ln -s $(readlink -f .)/bin/tahoe /usr/local/bin/tahoe
    popd
}
start_new_client() {
    client_dir=$1
    intro_furl=$2
    web_port=$3
    if [ ! -d "$client_dir" ]; then
        tahoe create-client --introducer=$intro_furl --webport=$web_port "$client_dir"
        perl -lni.bak -e 'print '\
'm/shares.happy/  && "shares.happy=5"  ||'\
'm/shares.needed/ && "shares.needed=2" ||'\
'm/shares.total/  && "shares.total=5"  ||'\
'm/tub.location/  && "tub.location=lafs.client.fakelocation:1" '\
'|| $_' "$client_dir/tahoe.cfg"
    fi
    ln -sf $(readlink -f $client_dir) ~/.tahoe
    [ "$(readlink -f ~/.tahoe)" != "$(readlink -f $client_dir)" ] && echo "~/.tahoe is not a symlink to $client_dir; aborting" && exit
    usewithtor tahoe restart
    # sudo iptables -I OUTPUT -p tcp -s 127.0.0.1 -d 127.0.0.1 --dport $web_port -j ACCEPT # not necessary if using the i2p web port which is already open (this iptables command opens the desired port but iceweasel still cannot connect if it isn't the i2p port)
}
wait_for_n_servers() {
    n=$1
    web_port=$2
    count=0
    while [ "$count" -lt "$n" ]; do
        count=$(http_proxy="" curl -s http://127.0.0.1:$web_port/|grep 'Connected to'|egrep -Eo '[0-9]+')
        echo -en "\x0d$(date) Connected to $count servers (waiting for $n)"
        sleep 1
    done
    echo
}
main $1
