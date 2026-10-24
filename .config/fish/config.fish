fish_add_path --path "$HOME/.local/bin"

function fish_prompt -d "Write out the prompt"
    # This shows up as USER@HOST /home/user/ >, with the directory colored
    # $USER and $hostname are set by fish, so you can just use them
    # instead of using `whoami` and `hostname`
    printf '%s@%s %s%s%s > ' $USER $hostname \
        (set_color $fish_color_cwd) (prompt_pwd) (set_color normal)
end

if status is-interactive
    # Commands to run in interactive sessions can go here
    set fish_greeting

end

starship init fish | source

alias pamcan=pacman

# Website blocking stuff

function chattr
    sleep 60
    command /usr/bin/chattr $argv  # Use the full path for `chattr` and pass arguments
end

function sudo
    # Check if the first argument is "chattr"
    if test "$argv[1]" = "chattr"
	echo Waiting for 5 hours...
        sleep 18000
        command sudo /usr/bin/chattr $argv[2..-1]  # Call `chattr` with sudo and remaining arguments
    else
        command sudo $argv  # Otherwise, pass through to regular sudo
    end
end

function ags_noproxy
    set -e http_proxy
    set -e https_proxy
    set -e HTTP_PROXY
    set -e HTTPS_PROXY
    ags $argv
end



# function fish_prompt
#   set_color cyan; echo (pwd)
#   set_color green; echo '> '
# end
