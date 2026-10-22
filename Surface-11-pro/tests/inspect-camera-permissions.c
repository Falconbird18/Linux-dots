#include <pipewire/pipewire.h>
#include <stdio.h>
static void global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version, const struct spa_dict *props) {
 const struct spa_dict_item *p;
 if (strstr(type,"Node") || strstr(type,"Client") || strstr(type,"Link")) {
  printf("%u %s",id,type);
  if(props) spa_dict_for_each(p,props) printf(" %s=%s",p->key,p->value);
  puts("");fflush(stdout);
 }
}
static void removed(void *d,uint32_t id) {printf("REMOVED %u\n",id);fflush(stdout);}
static const struct pw_registry_events events={PW_VERSION_REGISTRY_EVENTS,.global=global,.global_remove=removed};
int main(int argc,char **argv) {
 pw_init(&argc,&argv);
 struct pw_main_loop *loop=pw_main_loop_new(NULL);
 struct pw_context *ctx=pw_context_new(pw_main_loop_get_loop(loop),NULL,0);
 struct pw_core *core=pw_context_connect(ctx,pw_properties_new(PW_KEY_APP_NAME,(argc > 1 ? argv[1] : "surface11-test-portal"),NULL),0);
 if(!core)return 2;
 struct pw_registry *reg=pw_core_get_registry(core,PW_VERSION_REGISTRY,0);
 struct spa_hook hook;
 pw_registry_add_listener(reg,&hook,&events,NULL);
 pw_main_loop_run(loop);
 return 0;
}
