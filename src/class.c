/* vi: set ft=xs : */
#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "object_pad.h"
#include "class.h"
#include "field.h"

#undef register_class_attribute

#ifdef HAVE_DMD_HELPER
#  define WANT_DMD_API_044
#  include "DMD_helper.h"
#endif

#include "perl-backcompat.c.inc"
#include "sv_setrv.c.inc"

#include "perl-additions.c.inc"
#include "force_list_keeping_pushmark.c.inc"
#include "optree-additions.c.inc"
#include "newOP_CUSTOM.c.inc"
#include "cv_copy_flags.c.inc"

#ifdef DEBUGGING
#  define DEBUG_OVERRIDE_PLCURCOP
#  define DEBUG_SET_CURCOP_LINE(line)    CopLINE_set(PL_curcop, line)
#else
#  undef  DEBUG_OVERRIDE_PLCURCOP
#  define DEBUG_SET_CURCOP_LINE(line)
#endif

#define need_PLparser()  ClassPlain__need_PLparser(aTHX)
void ClassPlain__need_PLparser(pTHX); /* in Class/Plain.xs */

typedef struct ClassAttributeRegistration ClassAttributeRegistration;

struct ClassAttributeRegistration {
  ClassAttributeRegistration *next;

  const char *name;
  STRLEN permit_hintkeylen;

  const struct ClassHookFuncs *funcs;
  void *funcdata;
};

static ClassAttributeRegistration *classattrs = NULL;

static void register_class_attribute(const char *name, const struct ClassHookFuncs *funcs, void *funcdata)
{
  ClassAttributeRegistration *reg;
  Newx(reg, 1, struct ClassAttributeRegistration);

  reg->name = name;
  reg->funcs = funcs;
  reg->funcdata = funcdata;

  if(funcs->permit_hintkey)
    reg->permit_hintkeylen = strlen(funcs->permit_hintkey);
  else
    reg->permit_hintkeylen = 0;

  reg->next  = classattrs;
  classattrs = reg;
}

void ClassPlain_register_class_attribute(pTHX_ const char *name, const struct ClassHookFuncs *funcs, void *funcdata)
{
  if(funcs->ver < 57)
    croak("Mismatch in third-party class attribute ABI version field: module wants %d, we require >= 57\n",
        funcs->ver);
  if(funcs->ver > OBJECTPAD_ABIVERSION)
    croak("Mismatch in third-party class attribute ABI version field: attribute supplies %d, module wants %d\n",
        funcs->ver, OBJECTPAD_ABIVERSION);

  if(!name || !(name[0] >= 'A' && name[0] <= 'Z'))
    croak("Third-party class attribute names must begin with a capital letter");

  if(!funcs->permit_hintkey)
    croak("Third-party class attributes require a permit hinthash key");

  register_class_attribute(name, funcs, funcdata);
}

void ClassPlain_mop_class_apply_attribute(pTHX_ ClassMeta *classmeta, const char *name, SV *value)
{
  HV *hints = GvHV(PL_hintgv);

  if(value && (!SvPOK(value) || !SvCUR(value)))
    value = NULL;

  ClassAttributeRegistration *reg;
  for(reg = classattrs; reg; reg = reg->next) {
    if(!strEQ(name, reg->name))
      continue;

    if(reg->funcs->permit_hintkey &&
        (!hints || !hv_fetch(hints, reg->funcs->permit_hintkey, reg->permit_hintkeylen, 0)))
      continue;

    SV *hookdata = value;

    if(reg->funcs->apply) {
      if(!(*reg->funcs->apply)(aTHX_ classmeta, value, &hookdata, reg->funcdata))
        return;
    }

    if(!classmeta->hooks)
      classmeta->hooks = newAV();

    struct ClassHook *hook;
    Newx(hook, 1, struct ClassHook);

    hook->funcs = reg->funcs;
    hook->funcdata = reg->funcdata;
    hook->hookdata = hookdata;

    av_push(classmeta->hooks, (SV *)hook);

    if(value && value != hookdata)
      SvREFCNT_dec(value);

    return;
  }

  croak("Unrecognised class attribute :%s", name);
}

/* TODO: get attribute */

ClassMeta *ClassPlain_mop_get_class_for_stash(pTHX_ HV *stash)
{
  GV **gvp = (GV **)hv_fetchs(stash, "META", 0);
  if(!gvp)
    croak("Unable to find ClassMeta for %" HEKf, HEKfARG(HvNAME_HEK(stash)));

  return NUM2PTR(ClassMeta *, SvUV(SvRV(GvSV(*gvp))));
}

#define make_instance_fields(classmeta, backingav, roleoffset)  S_make_instance_fields(aTHX_ classmeta, backingav, roleoffset)
static void S_make_instance_fields(pTHX_ const ClassMeta *classmeta, AV *backingav, FIELDOFFSET roleoffset)
{
  assert(roleoffset == 0);

  if(classmeta->start_fieldix) {
    /* Superclass actually has some fields */
    assert(classmeta->type == METATYPE_CLASS);
    assert(classmeta->cls.supermeta->sealed);

    make_instance_fields(classmeta->cls.supermeta, backingav, 0);
  }

  AV *fields = classmeta->direct_fields;
  I32 nfields = av_count(fields);

  av_extend(backingav, classmeta->next_fieldix - 1 + roleoffset);

  I32 i;
  for(i = 0; i < nfields; i++) {
    av_push(backingav, newSV(0));
  }
}

SV *ClassPlain_get_obj_backingav(pTHX_ SV *self, enum ReprType repr, bool create)
{
  SV *rv = SvRV(self);

  return rv;
}

RoleEmbedding **ClassPlain_mop_class_get_direct_roles(pTHX_ const ClassMeta *meta, U32 *nroles)
{
  assert(meta->type == METATYPE_CLASS);
  AV *roles = meta->cls.direct_roles;
  *nroles = av_count(roles);
  return (RoleEmbedding **)AvARRAY(roles);
}

RoleEmbedding **ClassPlain_mop_class_get_all_roles(pTHX_ const ClassMeta *meta, U32 *nroles)
{
  assert(meta->type == METATYPE_CLASS);
  AV *roles = meta->cls.embedded_roles;
  *nroles = av_count(roles);
  return (RoleEmbedding **)AvARRAY(roles);
}

MethodMeta *ClassPlain_mop_class_add_method(pTHX_ ClassMeta *meta, SV *methodname)
{
  AV *methods = meta->direct_methods;

  if(meta->sealed)
    croak("Cannot add a new method to an already-sealed class");

  if(!methodname || !SvOK(methodname) || !SvCUR(methodname))
    croak("methodname must not be undefined or empty");

  U32 i;
  for(i = 0; i < av_count(methods); i++) {
    MethodMeta *methodmeta = (MethodMeta *)AvARRAY(methods)[i];
    if(sv_eq(methodmeta->name, methodname)) {
      if(methodmeta->role)
        croak("Method '%" SVf "' clashes with the one provided by role %" SVf,
          SVfARG(methodname), SVfARG(methodmeta->role->name));
      else
        croak("Cannot add another method named %" SVf, methodname);
    }
  }

  MethodMeta *methodmeta;
  Newx(methodmeta, 1, MethodMeta);

  methodmeta->name = SvREFCNT_inc(methodname);
  methodmeta->class = meta;
  methodmeta->role = NULL;

  av_push(methods, (SV *)methodmeta);

  return methodmeta;
}

FieldMeta *ClassPlain_mop_class_add_field(pTHX_ ClassMeta *meta, SV *fieldname)
{
  AV *fields = meta->direct_fields;

  if(meta->next_fieldix == -1)
    croak("Cannot add a new field to a class that is not yet begun");
  if(meta->sealed)
    croak("Cannot add a new field to an already-sealed class");

  if(!fieldname || !SvOK(fieldname) || !SvCUR(fieldname))
    croak("fieldname must not be undefined or empty");

  U32 i;
  for(i = 0; i < av_count(fields); i++) {
    FieldMeta *fieldmeta = (FieldMeta *)AvARRAY(fields)[i];
    if(SvCUR(fieldmeta->name) < 2)
      continue;

    if(sv_eq(fieldmeta->name, fieldname))
      croak("Cannot add another field named %" SVf, fieldname);
  }

  FieldMeta *fieldmeta = ClassPlain_mop_create_field(fieldname, meta);

  av_push(fields, (SV *)fieldmeta);
  meta->next_fieldix++;

  MOP_CLASS_RUN_HOOKS(meta, post_add_field, fieldmeta);

  return fieldmeta;
}

#define ClassPlain_mop_class_implements_role(meta, rolemeta)  S_mop_class_implements_role(aTHX_ meta, rolemeta)
static bool S_mop_class_implements_role(pTHX_ ClassMeta *meta, ClassMeta *rolemeta)
{
  U32 i, n;
  RoleEmbedding **embeddings = ClassPlain_mop_class_get_all_roles(meta, &n);
  for(i = 0; i < n; i++)
    if(embeddings[i]->rolemeta == rolemeta)
      return true;


  return false;
}

void ClassPlain_mop_class_seal(pTHX_ ClassMeta *meta)
{
  if(meta->sealed) /* idempotent */
    return;

  meta->sealed = true;
}

XS_INTERNAL(injected_constructor);
XS_INTERNAL(injected_constructor)
{
  dXSARGS;
  
  (void)items;
  
  XSRETURN(0);
}

ClassMeta *ClassPlain_mop_create_class(pTHX_ enum MetaType type, SV *name)
{
  assert(type == METATYPE_CLASS);

  ClassMeta *meta;
  Newx(meta, 1, ClassMeta);

  meta->type = type;
  meta->name = SvREFCNT_inc(name);

  meta->stash = gv_stashsv(name, GV_ADD);

  meta->sealed = false;
  meta->has_superclass = false;
  meta->start_fieldix = 0;
  meta->next_fieldix = -1;
  meta->hooks   = NULL;
  meta->direct_fields = newAV();
  meta->direct_methods = newAV();
  meta->parammap = NULL;

  meta->cls.supermeta = NULL;

  need_PLparser();

  meta->tmpcop = (COP *)newSTATEOP(0, NULL, NULL);
  CopFILE_set(meta->tmpcop, __FILE__);

  return meta;
}

void ClassPlain_mop_class_set_superclass(pTHX_ ClassMeta *meta, SV *superclassname)
{
  assert(meta->type == METATYPE_CLASS);

  if(meta->has_superclass)
    croak("Class already has a superclass, cannot add another");

  AV *isa;
  {
    SV *isaname = newSVpvf("%" SVf "::ISA", meta->name);
    SAVEFREESV(isaname);

    isa = get_av(SvPV_nolen(isaname), GV_ADD | (SvFLAGS(isaname) & SVf_UTF8));
  }

  av_push(isa, SvREFCNT_inc(superclassname));

  ClassMeta *supermeta = NULL;

  HV *superstash = gv_stashsv(superclassname, 0);
  GV **metagvp = (GV **)hv_fetchs(superstash, "META", 0);
  if(metagvp)
    supermeta = NUM2PTR(ClassMeta *, SvUV(SvRV(GvSV(*metagvp))));

  if(supermeta) {
    /* A subclass of an Class::Plain class */
    if(supermeta->type != METATYPE_CLASS)
      croak("%" SVf " is not a class", SVfARG(superclassname));

    /* If it isn't yet sealed (e.g. because we're an inner class of it),
     * seal it now
     */
    if(!supermeta->sealed)
      ClassPlain_mop_class_seal(supermeta);

    meta->start_fieldix = supermeta->next_fieldix;
    meta->repr = supermeta->repr;
  }
  else {
    meta->cls.foreign_does = fetch_superclass_method_pv(meta->stash, "DOES", 4, -1);
  }

  meta->has_superclass = true;
  meta->cls.supermeta = supermeta;
}

void ClassPlain_mop_class_begin(pTHX_ ClassMeta *meta)
{
  SV *isaname = newSVpvf("%" SVf "::ISA", meta->name);
  SAVEFREESV(isaname);

  AV *isa = get_av(SvPV_nolen(isaname), GV_ADD | (SvFLAGS(isaname) & SVf_UTF8));
  if(!av_count(isa))
    av_push(isa, newSVpvs("Class::Plain::Base"));

  if(meta->type == METATYPE_CLASS &&
      meta->repr == REPR_AUTOSELECT)
    meta->repr = REPR_NATIVE;

  meta->next_fieldix = meta->start_fieldix;
}

/*******************
 * Attribute hooks *
 *******************/

#ifndef isSPACE_utf8_safe
   /* this isn't really safe but it's the best we can do */
#  define isSPACE_utf8_safe(p, e)  (PERL_UNUSED_ARG(e), isSPACE_utf8(p))
#endif

#define split_package_ver(value, pkgname, pkgversion)  S_split_package_ver(aTHX_ value, pkgname, pkgversion)
static const char *S_split_package_ver(pTHX_ SV *value, SV *pkgname, SV *pkgversion)
{
  const char *start = SvPVX(value), *p = start, *end = start + SvCUR(value);

  while(*p && !isSPACE_utf8_safe(p, end))
    p += UTF8SKIP(p);

  sv_setpvn(pkgname, start, p - start);
  if(SvUTF8(value))
    SvUTF8_on(pkgname);

  while(*p && isSPACE_utf8_safe(p, end))
    p += UTF8SKIP(p);

  if(*p) {
    /* scan_version() gets upset about trailing content. We need to extract
     * exactly what it wants
     */
    start = p;
    if(*p == 'v')
      p++;
    while(*p && strchr("0123456789._", *p))
      p++;
    SV *tmpsv = newSVpvn(start, p - start);
    SAVEFREESV(tmpsv);

    scan_version(SvPVX(tmpsv), pkgversion, FALSE);
  }

  while(*p && isSPACE_utf8_safe(p, end))
    p += UTF8SKIP(p);

  return p;
}

/* :isa */

static bool classhook_isa_apply(pTHX_ ClassMeta *classmeta, SV *value, SV **hookdata_ptr, void *_funcdata)
{
  SV *superclassname = newSV(0), *superclassver = newSV(0);
  SAVEFREESV(superclassname);
  SAVEFREESV(superclassver);

  const char *end = split_package_ver(value, superclassname, superclassver);

  if(*end)
    croak("Unexpected characters while parsing :isa() attribute: %s", end);

  if(classmeta->type != METATYPE_CLASS)
    croak("Only a class may extend another");

  HV *superstash = gv_stashsv(superclassname, 0);
  // Original logic: if(!superstash || !hv_fetchs(superstash, "new", 0)) {
  if(!superstash) {
    /* Try to `require` the module then attempt a second time */
    /* load_module() will modify the name argument and take ownership of it */
    load_module(PERL_LOADMOD_NOIMPORT, newSVsv(superclassname), NULL, NULL);
    superstash = gv_stashsv(superclassname, 0);
  }

  if(!superstash)
    croak("Superclass %" SVf " does not exist", superclassname);

  if(superclassver && SvOK(superclassver))
    ensure_module_version(superclassname, superclassver);

  ClassPlain_mop_class_set_superclass(classmeta, superclassname);

  return FALSE;
}

static const struct ClassHookFuncs classhooks_isa = {
  .ver   = OBJECTPAD_ABIVERSION,
  .apply = &classhook_isa_apply,
};

void ClassPlain__boot_classes(pTHX)
{
  register_class_attribute("isa",    &classhooks_isa,    NULL);
}
