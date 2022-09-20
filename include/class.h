#ifndef __CLASS_PLAIN__CLASS_H__
#define __CLASS_PLAIN__CLASS_H__

/* Metadata about a class */
struct ClassMeta {
  SV *name;
  AV *hooks;           /* NULL, or AV of raw pointers directly to ClassHook structs */
  AV *fields;   /* each elem is a raw pointer directly to a FieldMeta */
  AV *methods;  /* each elem is a raw pointer directly to a MethodMeta */
};

struct MethodMeta {
  SV *name;
  ClassMeta *class;
  /* We don't store the method body CV; leave that in the class stash */
  unsigned int is_common : 1;
};

#define MOP_CLASS_RUN_HOOKS(classmeta, func, ...)                                         \
  {                                                                                       \
    U32 hooki;                                                                            \
    for(hooki = 0; classmeta->hooks && hooki < av_count(classmeta->hooks); hooki++) {     \
      struct ClassHook *h = (struct ClassHook *)AvARRAY(classmeta->hooks)[hooki];         \
      if(*h->funcs->func)                                                                 \
        (*h->funcs->func)(aTHX_ classmeta, h->hookdata, h->funcdata, __VA_ARGS__);        \
    }                                                                                     \
  }

void ClassPlain__boot_classes(pTHX);

#endif
