/* Trusted equivalent of the small repository-local Python checks. It runs
 * inside the production immutable root with only the admitted workspace. */
#include <stdio.h>
#include <string.h>

static int exact(const char *path, const char *wanted) {
  char buffer[256] = {0};
  FILE *file = fopen(path, "r");
  if (!file) return 0;
  size_t size = fread(buffer, 1, sizeof(buffer) - 1, file);
  int valid = !ferror(file) && feof(file) && size == strlen(wanted) && !memcmp(buffer, wanted, size);
  fclose(file);
  return valid;
}

int main(int argc, char **argv) {
  if (argc != 2) return 64;
  int valid = 0;
  if (!strcmp(argv[1], "producer"))
    valid = exact("/workspace/record.json", "{\"version\":2,\"value\":{\"text\":\"hello\"}}\n");
  if (!strcmp(argv[1], "consumer"))
    valid = exact("/workspace/contract.json", "{\"version\":1,\"path\":[\"text\"]}\n") ||
            exact("/workspace/contract.json", "{\"version\":2,\"path\":[\"value\",\"text\"]}\n");
  if (!valid) return 77;
  puts("local schema check passed; combined journey still required");
  return 0;
}
