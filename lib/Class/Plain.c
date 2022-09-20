/*
 * This file was generated automatically by ExtUtils::ParseXS version 3.40 from the
 * contents of Plain.xs. Do not edit this file, edit Plain.xs instead.
 *
 *    ANY CHANGES MADE HERE WILL BE LOST!
 *
 */

#line 1 "lib/Class/Plain.xs"
/*  You may distribute under the terms of either the GNU General Public License
 *  or the Artistic License (the same terms as Perl itself)
 *
 *  (C) Paul Evans, 2019-2021 -- leonerd@leonerd.org.uk
 */
#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "XSParseKeyword.h"

#include "XSParseSublike.h"

#include "perl-backcompat.c.inc"
#include "sv_setrv.c.inc"

#include "perl-additions.c.inc"
#include "lexer-additions.c.inc"
#include "forbid_outofblock_ops.c.inc"
#include "force_list_keeping_pushmark.c.inc"
#include "optree-additions.c.inc"
#include "newOP_CUSTOM.c.inc"

#include "meta.h"
#include "class.h"
#include "field.h"

typedef void MethodAttributeHandler(pTHX_ MethodMeta *meta, const char *value, void *data);

struct MethodAttributeDefinition {
  char *attrname;
  /* TODO: int flags */
  MethodAttributeHandler *apply;
  void *applydata;
};

/**********************************
 * Class and Field Implementation *
 **********************************/

static XOP xop_methstart;
static OP *pp_methstart(pTHX)
{
  SV *self = av_shift(GvAV(PL_defgv));

  if(!SvROK(self) || !SvOBJECT(SvRV(self)))
    croak("Cannot invoke method on a non-instance");

  save_clearsv(&PAD_SVl(1));
  sv_setsv(PAD_SVl(1), self);

  return PL_op->op_next;
}

OP *ClassPlain_newMETHSTARTOP(pTHX_ U32 flags)
{
  OP *op = newOP_CUSTOM(&pp_methstart, flags);
  op->op_private = (U8)(flags >> 8);
  return op;
}

static XOP xop_commonmethstart;
static OP *pp_commonmethstart(pTHX)
{
  SV *self = av_shift(GvAV(PL_defgv));

  if(SvROK(self))
    /* TODO: Should handle this somehow */
    croak("Cannot invoke common method on an instance");

  save_clearsv(&PAD_SVl(1));
  sv_setsv(PAD_SVl(1), self);

  return PL_op->op_next;
}

OP *ClassPlain_newCOMMONMETHSTARTOP(pTHX_ U32 flags)
{
  OP *op = newOP_CUSTOM(&pp_commonmethstart, flags);
  op->op_private = (U8)(flags >> 8);
  return op;
}

/* The metadata on the currently-compiling class */
#define compclassmeta       S_compclassmeta(aTHX)
static ClassMeta *S_compclassmeta(pTHX)
{
  SV **svp = hv_fetchs(GvHV(PL_hintgv), "Class::Plain/compclassmeta", 0);
  if(!svp || !*svp || !SvOK(*svp))
    return NULL;
  return (ClassMeta *)SvIV(*svp);
}

#define have_compclassmeta  S_have_compclassmeta(aTHX)
static bool S_have_compclassmeta(pTHX)
{
  SV **svp = hv_fetchs(GvHV(PL_hintgv), "Class::Plain/compclassmeta", 0);
  if(!svp || !*svp)
    return false;

  if(SvOK(*svp) && SvIV(*svp))
    return true;

  return false;
}

#define compclassmeta_set(meta)  S_compclassmeta_set(aTHX_ meta)
static void S_compclassmeta_set(pTHX_ ClassMeta *meta)
{
  SV *sv = *hv_fetchs(GvHV(PL_hintgv), "Class::Plain/compclassmeta", GV_ADD);
  sv_setiv(sv, (IV)meta);
}

#define is_valid_ident_utf8(s)  S_is_valid_ident_utf8(aTHX_ s)
static bool S_is_valid_ident_utf8(pTHX_ const U8 *s)
{
  const U8 *e = s + strlen((char *)s);

  if(!isIDFIRST_utf8_safe(s, e))
    return false;

  s += UTF8SKIP(s);
  while(*s) {
    if(!isIDCONT_utf8_safe(s, e))
      return false;
    s += UTF8SKIP(s);
  }

  return true;
}

static void inplace_trim_whitespace(SV *sv)
{
  if(!SvPOK(sv) || !SvCUR(sv))
    return;

  char *dst = SvPVX(sv);
  char *src = dst;

  while(*src && isSPACE(*src))
    src++;

  if(src > dst) {
    size_t offset = src - dst;
    Move(src, dst, SvCUR(sv) - offset, char);
    SvCUR(sv) -= offset;
  }

  src = dst + SvCUR(sv) - 1;
  while(src > dst && isSPACE(*src))
    src--;

  SvCUR(sv) = src - dst + 1;
  dst[SvCUR(sv)] = 0;
}

static void S_apply_method_common(pTHX_ MethodMeta *meta, const char *val, void *_data)
{
  meta->is_common = true;
}

static struct MethodAttributeDefinition method_attributes[] = {
  { "common",   &S_apply_method_common,   NULL },
  { 0 }
};

/*******************
 * Custom Keywords *
 *******************/

static int build_classlike(pTHX_ OP **out, XSParseKeywordPiece *args[], size_t nargs, void *hookdata)
{
  int argi = 0;

  SV *packagename = args[argi++]->sv;
  /* Grrr; XPK bug */
  if(!packagename)
    croak("Expected a class name after 'class'");

  IV type = (IV)hookdata;

  SV *packagever = args[argi++]->sv;

  SV *superclassname = NULL;

  if(args[argi++]->i) {
    /* extends */
    argi++; /* ignore the XPK_CHOICE() integer; `extends` and `isa` are synonyms */

    if(superclassname)
      croak("Multiple superclasses are not currently supported");

    superclassname = args[argi++]->sv;
    if(!superclassname)
      croak("Expected a superclass name after 'isa'");

    SV *superclassver = args[argi++]->sv;

    HV *superstash = gv_stashsv(superclassname, 0);
    if(!superstash || !hv_fetchs(superstash, "new", 0)) {
      /* Try to `require` the module then attempt a second time */
      /* load_module() will modify the name argument and take ownership of it */
      load_module(PERL_LOADMOD_NOIMPORT, newSVsv(superclassname), NULL, NULL);
      superstash = gv_stashsv(superclassname, 0);
    }

    if(!superstash)
      croak("Superclass %" SVf " does not exist", superclassname);

    if(superclassver)
      ensure_module_version(superclassname, superclassver);
  }

  ClassMeta *meta = ClassPlain_mop_create_class(type, packagename);

  if(superclassname && SvOK(superclassname))
    ClassPlain_mop_class_set_superclass(meta, superclassname);

  if(superclassname)
    SvREFCNT_dec(superclassname);

  int nattrs = args[argi++]->i;
  if(nattrs) {
    if(hv_fetchs(GvHV(PL_hintgv), "Class::Plain/configure(no_class_attrs)", 0))
      croak("Class attributes are not permitted");

    int i;
    for(i = 0; i < nattrs; i++) {
      SV *attrname = args[argi]->attr.name;
      SV *attrval  = args[argi]->attr.value;

      inplace_trim_whitespace(attrval);

      ClassPlain_mop_class_apply_attribute(meta, SvPVX(attrname), attrval);

      argi++;
    }
  }

  if(hv_fetchs(GvHV(PL_hintgv), "Class::Plain/configure(always_strict)", 0)) {
    ClassPlain_mop_class_apply_attribute(meta, "strict", sv_2mortal(newSVpvs("params")));
  }

  ClassPlain_mop_class_begin(meta);

  /* At this point XS::Parse::Keyword has parsed all it can. From here we will
   * take over to perform the odd "block or statement" behaviour of `class`
   * keywords
   */

  bool is_block;

  if(lex_consume_unichar('{')) {
    is_block = true;
    ENTER;
  }
  else if(lex_consume_unichar(';')) {
    is_block = false;
  }
  else
    croak("Expected a block or ';'");

  /* CARGOCULT from perl/op.c:Perl_package() */
  {
    SAVEGENERICSV(PL_curstash);
    save_item(PL_curstname);

    PL_curstash = (HV *)SvREFCNT_inc(gv_stashsv(meta->name, GV_ADD));
    sv_setsv(PL_curstname, packagename);

    PL_hints |= HINT_BLOCK_SCOPE;
    PL_parser->copline = NOLINE;
  }

  if(packagever) {
    /* stolen from op.c because Perl_package_version isn't exported */
    U32 savehints = PL_hints;
    PL_hints &= ~HINT_STRICT_VARS;

    sv_setsv(GvSV(gv_fetchpvs("VERSION", GV_ADDMULTI, SVt_PV)), packagever);

    PL_hints = savehints;
  }

  if(is_block) {
    I32 save_ix = block_start(TRUE);
    compclassmeta_set(meta);

    OP *body = parse_stmtseq(0);
    body = block_end(save_ix, body);

    if(!lex_consume_unichar('}'))
      croak("Expected }");

    LEAVE;

    /* CARGOCULT from perl/perly.y:PACKAGE BAREWORD BAREWORD '{' */
    /* a block is a loop that happens once */
    *out = op_append_elem(OP_LINESEQ,
      newWHILEOP(0, 1, NULL, NULL, body, NULL, 0),
      newSVOP(OP_CONST, 0, &PL_sv_yes));
    return KEYWORD_PLUGIN_STMT;
  }
  else {
    SAVEHINTS();
    compclassmeta_set(meta);

    *out = newSVOP(OP_CONST, 0, &PL_sv_yes);
    return KEYWORD_PLUGIN_STMT;
  }
}

static const struct XSParseKeywordPieceType pieces_classlike[] = {
  XPK_PACKAGENAME,
  XPK_VSTRING_OPT,
  XPK_OPTIONAL(
    XPK_CHOICE(XPK_LITERAL("isa") ), XPK_PACKAGENAME, XPK_VSTRING_OPT
  ),
  /* This should really a repeated (tagged?) choice of a number of things, but
   * right now there's only one thing permitted here anyway
   */
  XPK_ATTRIBUTES,
  {0}
};

static const struct XSParseKeywordHooks kwhooks_class = {
  .pieces = pieces_classlike,
  .build = &build_classlike,
};

static void check_field(pTHX_ void *hookdata)
{
  char *kwname = hookdata;
  
  if(!have_compclassmeta)
    croak("Cannot '%s' outside of 'class'", kwname);

  if(!sv_eq(PL_curstname, compclassmeta->name))
    croak("Current package name no longer matches current class (%" SVf " vs %" SVf ")",
      PL_curstname, compclassmeta->name);
}

static int build_field(pTHX_ OP **out, XSParseKeywordPiece *args[], size_t nargs, void *hookdata)
{
  int argi = 0;

  SV *name = args[argi++]->sv;

  FieldMeta *fieldmeta = ClassPlain_mop_class_add_field(compclassmeta, name);
  SvREFCNT_dec(name);

  int nattrs = args[argi++]->i;
  if(nattrs) {
    if(hv_fetchs(GvHV(PL_hintgv), "Class::Plain/configure(no_field_attrs)", 0))
      croak("Field attributes are not permitted");

    while(argi < (nattrs+2)) {
      SV *attrname = args[argi]->attr.name;
      SV *attrval  = args[argi]->attr.value;

      inplace_trim_whitespace(attrval);

      ClassPlain_mop_field_apply_attribute(fieldmeta, SvPVX(attrname), attrval);

      if(attrval)
        SvREFCNT_dec(attrval);

      argi++;
    }
  }

  return KEYWORD_PLUGIN_STMT;
}

static void setup_parse_field_initexpr(pTHX_ void *hookdata)
{
  CV *was_compcv = PL_compcv;
  HV *hints = GvHV(PL_hintgv);

  if(!hints || !hv_fetchs(hints, "Class::Plain/experimental(init_expr)", 0))
    Perl_ck_warner(aTHX_ packWARN(WARN_EXPERIMENTAL),
      "field initialiser expression is experimental and may be changed or removed without notice");

  /* Set up this new block as if the current compiler context were its scope */

  if(CvOUTSIDE(PL_compcv))
    SvREFCNT_dec(CvOUTSIDE(PL_compcv));

  CvOUTSIDE(PL_compcv)     = (CV *)SvREFCNT_inc(was_compcv);
  CvOUTSIDE_SEQ(PL_compcv) = PL_cop_seqmax;
}

static const struct XSParseKeywordHooks kwhooks_field = {
  .flags = XPK_FLAG_STMT,

  .check = &check_field,

  .pieces = (const struct XSParseKeywordPieceType []){
    XPK_IDENT,
    XPK_ATTRIBUTES,
    {0}
  },
  .build = &build_field,
};
static bool parse_method_permit(pTHX_ void *hookdata)
{
  if(!have_compclassmeta)
    croak("Cannot 'method' outside of 'class'");

  if(!sv_eq(PL_curstname, compclassmeta->name))
    croak("Current package name no longer matches current class (%" SVf " vs %" SVf ")",
      PL_curstname, compclassmeta->name);

  return true;
}

static void parse_method_pre_subparse(pTHX_ struct XSParseSublikeContext *ctx, void *hookdata)
{
  /* While creating the new scope CV we need to ENTER a block so as not to
   * break any interpvars
   */
  ENTER;
  SAVESPTR(PL_comppad);
  SAVESPTR(PL_comppad_name);
  SAVESPTR(PL_curpad);

  intro_my();

  MethodMeta *compmethodmeta;
  Newx(compmethodmeta, 1, MethodMeta);

  compmethodmeta->name = SvREFCNT_inc(ctx->name);
  compmethodmeta->class = NULL;
  compmethodmeta->is_common = false;

  hv_stores(ctx->moddata, "Class::Plain/compmethodmeta", newSVuv(PTR2UV(compmethodmeta)));

  LEAVE;
}

static bool parse_method_filter_attr(pTHX_ struct XSParseSublikeContext *ctx, SV *attr, SV *val, void *hookdata)
{
  MethodMeta *compmethodmeta = NUM2PTR(MethodMeta *, SvUV(*hv_fetchs(ctx->moddata, "Class::Plain/compmethodmeta", 0)));

  struct MethodAttributeDefinition *def;
  for(def = method_attributes; def->attrname; def++) {
    if(!strEQ(SvPVX(attr), def->attrname))
      continue;

    /* TODO: We might want to wrap the CV in some sort of MethodMeta struct
     * but for now we'll just pass the XSParseSublikeContext context */
    (*def->apply)(aTHX_ compmethodmeta, SvPOK(val) ? SvPVX(val) : NULL, def->applydata);

    return true;
  }

  /* No error, just let it fall back to usual attribute handling */
  return false;
}

static void parse_method_post_blockstart(pTHX_ struct XSParseSublikeContext *ctx, void *hookdata)
{
  MethodMeta *compmethodmeta = NUM2PTR(MethodMeta *, SvUV(*hv_fetchs(ctx->moddata, "Class::Plain/compmethodmeta", 0)));
  if(compmethodmeta->is_common) {
    IV var_index = pad_add_name_pvs("$class", 0, NULL, NULL);
    if (!(var_index == 1)) {
      croak("[Unexpected]Invalid index of the $class variable:%d", (int)var_index);
    }
  }
  else {
    IV var_index = pad_add_name_pvs("$self", 0, NULL, NULL);
    if(var_index != 1) {
      croak("[Unexpected]Invalid index of the $self variable:%d", (int)var_index);
    }
  }

  intro_my();
}

static void parse_method_pre_blockend(pTHX_ struct XSParseSublikeContext *ctx, void *hookdata)
{
  MethodMeta *compmethodmeta = NUM2PTR(MethodMeta *, SvUV(*hv_fetchs(ctx->moddata, "Class::Plain/compmethodmeta", 0)));

  /* If we have no ctx->body that means this was a bodyless method
   * declaration; a required method
   */
  if(compmethodmeta->is_common) {
    ctx->body = op_append_list(OP_LINESEQ,
      ClassPlain_newCOMMONMETHSTARTOP(0 |
        (0)),
      ctx->body);
  }
  else {
    OP *fieldops = NULL, *methstartop;
    fieldops = op_append_list(OP_LINESEQ, fieldops,
      newSTATEOP(0, NULL, NULL));
    fieldops = op_append_list(OP_LINESEQ, fieldops,
      (methstartop = ClassPlain_newMETHSTARTOP(0 |
        (0) |
        (0))));

    ctx->body = op_append_list(OP_LINESEQ, fieldops, ctx->body);
  }
}

static void parse_method_post_newcv(pTHX_ struct XSParseSublikeContext *ctx, void *hookdata)
{
  MethodMeta *compmethodmeta;
  {
    SV *tmpsv = *hv_fetchs(ctx->moddata, "Class::Plain/compmethodmeta", 0);
    compmethodmeta = NUM2PTR(MethodMeta *, SvUV(tmpsv));
    sv_setuv(tmpsv, 0);
  }

  if(ctx->cv)
    CvMETHOD_on(ctx->cv);

    if(ctx->cv && ctx->name && (ctx->actions & XS_PARSE_SUBLIKE_ACTION_INSTALL_SYMBOL)) {
      MethodMeta *meta = ClassPlain_mop_class_add_method(compclassmeta, ctx->name);

      meta->is_common = compmethodmeta->is_common;
    }

  SvREFCNT_dec(compmethodmeta->name);
  Safefree(compmethodmeta);
}

static struct XSParseSublikeHooks parse_method_hooks = {
  .flags           = XS_PARSE_SUBLIKE_FLAG_FILTERATTRS |
                     XS_PARSE_SUBLIKE_COMPAT_FLAG_DYNAMIC_ACTIONS |
                     XS_PARSE_SUBLIKE_FLAG_BODY_OPTIONAL,
  .permit          = parse_method_permit,
  .pre_subparse    = parse_method_pre_subparse,
  .filter_attr     = parse_method_filter_attr,
  .post_blockstart = parse_method_post_blockstart,
  .pre_blockend    = parse_method_pre_blockend,
  .post_newcv      = parse_method_post_newcv,
};

struct CustomFieldHookData
{
  SV *apply_cb;
};

/* internal function shared by various *.c files */
void ClassPlain_need_PLparser(pTHX)
{
  if(!PL_parser) {
    /* We need to generate just enough of a PL_parser to keep newSTATEOP()
     * happy, otherwise it will SIGSEGV (RT133258)
     */
    SAVEVPTR(PL_parser);
    Newxz(PL_parser, 1, yy_parser);
    SAVEFREEPV(PL_parser);

    PL_parser->copline = NOLINE;
  }
}

#line 572 "lib/Class/Plain.c"
#ifndef PERL_UNUSED_VAR
#  define PERL_UNUSED_VAR(var) if (0) var = var
#endif

#ifndef dVAR
#  define dVAR		dNOOP
#endif


/* This stuff is not part of the API! You have been warned. */
#ifndef PERL_VERSION_DECIMAL
#  define PERL_VERSION_DECIMAL(r,v,s) (r*1000000 + v*1000 + s)
#endif
#ifndef PERL_DECIMAL_VERSION
#  define PERL_DECIMAL_VERSION \
	  PERL_VERSION_DECIMAL(PERL_REVISION,PERL_VERSION,PERL_SUBVERSION)
#endif
#ifndef PERL_VERSION_GE
#  define PERL_VERSION_GE(r,v,s) \
	  (PERL_DECIMAL_VERSION >= PERL_VERSION_DECIMAL(r,v,s))
#endif
#ifndef PERL_VERSION_LE
#  define PERL_VERSION_LE(r,v,s) \
	  (PERL_DECIMAL_VERSION <= PERL_VERSION_DECIMAL(r,v,s))
#endif

/* XS_INTERNAL is the explicit static-linkage variant of the default
 * XS macro.
 *
 * XS_EXTERNAL is the same as XS_INTERNAL except it does not include
 * "STATIC", ie. it exports XSUB symbols. You probably don't want that
 * for anything but the BOOT XSUB.
 *
 * See XSUB.h in core!
 */


/* TODO: This might be compatible further back than 5.10.0. */
#if PERL_VERSION_GE(5, 10, 0) && PERL_VERSION_LE(5, 15, 1)
#  undef XS_EXTERNAL
#  undef XS_INTERNAL
#  if defined(__CYGWIN__) && defined(USE_DYNAMIC_LOADING)
#    define XS_EXTERNAL(name) __declspec(dllexport) XSPROTO(name)
#    define XS_INTERNAL(name) STATIC XSPROTO(name)
#  endif
#  if defined(__SYMBIAN32__)
#    define XS_EXTERNAL(name) EXPORT_C XSPROTO(name)
#    define XS_INTERNAL(name) EXPORT_C STATIC XSPROTO(name)
#  endif
#  ifndef XS_EXTERNAL
#    if defined(HASATTRIBUTE_UNUSED) && !defined(__cplusplus)
#      define XS_EXTERNAL(name) void name(pTHX_ CV* cv __attribute__unused__)
#      define XS_INTERNAL(name) STATIC void name(pTHX_ CV* cv __attribute__unused__)
#    else
#      ifdef __cplusplus
#        define XS_EXTERNAL(name) extern "C" XSPROTO(name)
#        define XS_INTERNAL(name) static XSPROTO(name)
#      else
#        define XS_EXTERNAL(name) XSPROTO(name)
#        define XS_INTERNAL(name) STATIC XSPROTO(name)
#      endif
#    endif
#  endif
#endif

/* perl >= 5.10.0 && perl <= 5.15.1 */


/* The XS_EXTERNAL macro is used for functions that must not be static
 * like the boot XSUB of a module. If perl didn't have an XS_EXTERNAL
 * macro defined, the best we can do is assume XS is the same.
 * Dito for XS_INTERNAL.
 */
#ifndef XS_EXTERNAL
#  define XS_EXTERNAL(name) XS(name)
#endif
#ifndef XS_INTERNAL
#  define XS_INTERNAL(name) XS(name)
#endif

/* Now, finally, after all this mess, we want an ExtUtils::ParseXS
 * internal macro that we're free to redefine for varying linkage due
 * to the EXPORT_XSUB_SYMBOLS XS keyword. This is internal, use
 * XS_EXTERNAL(name) or XS_INTERNAL(name) in your code if you need to!
 */

#undef XS_EUPXS
#if defined(PERL_EUPXS_ALWAYS_EXPORT)
#  define XS_EUPXS(name) XS_EXTERNAL(name)
#else
   /* default to internal */
#  define XS_EUPXS(name) XS_INTERNAL(name)
#endif

#ifndef PERL_ARGS_ASSERT_CROAK_XS_USAGE
#define PERL_ARGS_ASSERT_CROAK_XS_USAGE assert(cv); assert(params)

/* prototype to pass -Wmissing-prototypes */
STATIC void
S_croak_xs_usage(const CV *const cv, const char *const params);

STATIC void
S_croak_xs_usage(const CV *const cv, const char *const params)
{
    const GV *const gv = CvGV(cv);

    PERL_ARGS_ASSERT_CROAK_XS_USAGE;

    if (gv) {
        const char *const gvname = GvNAME(gv);
        const HV *const stash = GvSTASH(gv);
        const char *const hvname = stash ? HvNAME(stash) : NULL;

        if (hvname)
	    Perl_croak_nocontext("Usage: %s::%s(%s)", hvname, gvname, params);
        else
	    Perl_croak_nocontext("Usage: %s(%s)", gvname, params);
    } else {
        /* Pants. I don't think that it should be possible to get here. */
	Perl_croak_nocontext("Usage: CODE(0x%" UVxf ")(%s)", PTR2UV(cv), params);
    }
}
#undef  PERL_ARGS_ASSERT_CROAK_XS_USAGE

#define croak_xs_usage        S_croak_xs_usage

#endif

/* NOTE: the prototype of newXSproto() is different in versions of perls,
 * so we define a portable version of newXSproto()
 */
#ifdef newXS_flags
#define newXSproto_portable(name, c_impl, file, proto) newXS_flags(name, c_impl, file, proto, 0)
#else
#define newXSproto_portable(name, c_impl, file, proto) (PL_Sv=(SV*)newXS(name, c_impl, file), sv_setpv(PL_Sv, proto), (CV*)PL_Sv)
#endif /* !defined(newXS_flags) */

#if PERL_VERSION_LE(5, 21, 5)
#  define newXS_deffile(a,b) Perl_newXS(aTHX_ a,b,file)
#else
#  define newXS_deffile(a,b) Perl_newXS_deffile(aTHX_ a,b)
#endif

#line 716 "lib/Class/Plain.c"
#ifdef __cplusplus
extern "C"
#endif
XS_EXTERNAL(boot_Class__Plain); /* prototype to pass -Wmissing-prototypes */
XS_EXTERNAL(boot_Class__Plain)
{
#if PERL_VERSION_LE(5, 21, 5)
    dVAR; dXSARGS;
#else
    dVAR; dXSBOOTARGSXSAPIVERCHK;
#endif

    PERL_UNUSED_VAR(cv); /* -W */
    PERL_UNUSED_VAR(items); /* -W */
#if PERL_VERSION_LE(5, 21, 5)
    XS_VERSION_BOOTCHECK;
#  ifdef XS_APIVERSION_BOOTCHECK
    XS_APIVERSION_BOOTCHECK;
#  endif
#endif


    /* Initialisation Section */

#line 565 "lib/Class/Plain.xs"
  XopENTRY_set(&xop_methstart, xop_name, "methstart");
  XopENTRY_set(&xop_methstart, xop_desc, "enter method");
  XopENTRY_set(&xop_methstart, xop_class, OA_BASEOP);
  Perl_custom_op_register(aTHX_ &pp_methstart, &xop_methstart);

  XopENTRY_set(&xop_commonmethstart, xop_name, "commonmethstart");
  XopENTRY_set(&xop_commonmethstart, xop_desc, "enter method :common");
  XopENTRY_set(&xop_commonmethstart, xop_class, OA_BASEOP);
  Perl_custom_op_register(aTHX_ &pp_commonmethstart, &xop_commonmethstart);

  boot_xs_parse_keyword(0.22); /* XPK_AUTOSEMI */

  register_xs_parse_keyword("class", &kwhooks_class, (void *)0);
  register_xs_parse_keyword("field", &kwhooks_field, "field");

  boot_xs_parse_sublike(0.15); /* dynamic actions */

  register_xs_parse_sublike("method", &parse_method_hooks, (void *)0);

  ClassPlain__boot_classes(aTHX);
  ClassPlain__boot_fields(aTHX);

#line 764 "lib/Class/Plain.c"

    /* End of Initialisation Section */

#if PERL_VERSION_LE(5, 21, 5)
#  if PERL_VERSION_GE(5, 9, 0)
    if (PL_unitcheckav)
        call_list(PL_scopestack_ix, PL_unitcheckav);
#  endif
    XSRETURN_YES;
#else
    Perl_xs_boot_epilog(aTHX_ ax);
#endif
}

