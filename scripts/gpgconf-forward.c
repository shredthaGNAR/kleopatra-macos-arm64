#include <unistd.h>
#include <stdio.h>
int main(int argc, char **argv) {
    (void)argc;
    argv[0] = "/opt/homebrew/bin/gpgconf";
    execv(argv[0], argv);
    perror("Kleopatra: cannot launch Homebrew gpgconf");
    return 127;
}
