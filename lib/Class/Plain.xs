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

#ifdef HAVE_DMD_HELPER
#  define WANT_DMD_API_044
#  include "DMD_helper.h"
#endif

#include "perl-additions.c.inc"
#include "lexer-additions.c.inc"
#include "forbid_outofblock_ops.c.inc"
#include "force_list_keeping_pushmark.c.inc"
#include "optree-additions.c.inc"
#include "newOP_CUSTOM.c.inc"

#if HAVE_PERL_VERSION(5, 26, 0)
#  define HAVE_PARSE_SUBSIGNATURE
#endif

#if HAVE_PERL_VERSION(5, 28, 0)
#  define HAVE_UNOP_AUX_PV
#endif

#ifdef HAVE_UNOP_AUX
#  define METHSTART_CONTAINS_FIELD_BINDINGS

/* We'll reserve the top two bits of a UV for storing the `type` value for a
 * fieldpad operation; the remainder stores the fieldix itself */
#  define UVBITS (UVSIZE*8)
#  define FIELDIX_TYPE_SHIFT  (UVBITS-2)
#  define FIELDIX_MASK        ((1LL<<FIELDIX_TYPE_SHIFT)-1)
#endif

#include "object_pad.h"
#include "class.h"
#include "field.h"

#define warn_deprecated(...)  Perl_ck_warner(aTHX_ packWARN(WARN_DEPRECATED), __VA_ARGS__)

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

void ClassPlain_extend_pad_vars(pTHX_ const ClassMeta *meta)
{
  PADOFFSET padix;

  padix = pad_add_name_pvs("$self", 0, NULL, NULL);
  if(padix != PADIX_SELF)
    croak("ARGH: Expected that padix[$self] = 1");

  /* Give it a name that isn't valid as a Perl variable so it can't collide */
  padix = pad_add_name_pvs("@(Class::Plain/slots)", 0, NULL, NULL);
  if(padix != PADIX_SLOTS)
    croak("ARGH: Expected that padix[@slots] = 2");
}

#define find_padix_for_field(fieldmeta)  S_find_padix_for_field(aTHX_ fieldmeta)
static PADOFFSET S_find_padix_for_field(pTHX_ FieldMeta *fieldmeta)
{
  const char *fieldname = SvPVX(fieldmeta->name);
#if HAVE_PERL_VERSION(5, 20, 0)
  const PADNAMELIST *nl = PadlistNAMES(CvPADLIST(PL_compcv));
  PADNAME **names = PadnamelistARRAY(nl);
  PADOFFSET padix;

  for(padix = 1; padix <= PadnamelistMAXNAMED(nl); padix++) {
    PADNAME *name = names[padix];

    if(!name || !PadnameLEN(name))
      continue;

    const char *pv = PadnamePV(name);
    if(!pv)
      continue;

    /* field names are all OUTER vars. This is necessary so we don't get
     * confused by signatures params of the same name
     *   https://rt.cpan.org/Ticket/Display.html?id=134456
     */
    if(!PadnameOUTER(name))
      continue;
    if(!strEQ(pv, fieldname))
      continue;

    /* TODO: for extra robustness we could compare the SV * in the pad itself */

    return padix;
  }

  return NOT_IN_PAD;
#else
  /* Before the new pad API, the best we can do is call pad_findmy_pv()
   * It won't get confused about signatures params because these perls are too
   * old for signatures anyway
   */
  return pad_findmy_pv(fieldname, 0);
#endif
}

#define bind_field_to_pad(sv, fieldix, private, padix)  S_bind_field_to_pad(aTHX_ sv, fieldix, private, padix)
static void S_bind_field_to_pad(pTHX_ SV *sv, FIELDOFFSET fieldix, U8 private, PADOFFSET padix)
{
  SV *val;
  val = sv;
  SAVESPTR(PAD_SVl(padix));
  PAD_SVl(padix) = SvREFCNT_inc(val);
  save_freesv(val);
}

static XOP xop_methstart;
static OP *pp_methstart(pTHX)
{
  SV *self = av_shift(GvAV(PL_defgv));
  bool create = PL_op->op_flags & OPf_MOD;

  if(!SvROK(self) || !SvOBJECT(SvRV(self)))
    croak("Cannot invoke method on a non-instance");

  save_clearsv(&PAD_SVl(PADIX_SELF));
  sv_setsv(PAD_SVl(PADIX_SELF), self);

  AV *backingav;

  /* op_private contains the repr type so we can extract backing */
  backingav = (AV *)ClassPlain_get_obj_backingav(self, PL_op->op_private, create);
  SvREFCNT_inc(backingav);

  if(backingav) {
    SAVESPTR(PAD_SVl(PADIX_SLOTS));
    PAD_SVl(PADIX_SLOTS) = (SV *)backingav;
    save_freesv((SV *)backingav);
  }

#ifdef METHSTART_CONTAINS_FIELD_BINDINGS
  UNOP_AUX_item *aux = cUNOP_AUX->op_aux;
  if(aux) {
    U32 fieldcount  = (aux++)->uv;
    U32 max_fieldix = (aux++)->uv;
    SV **fieldsvs = AvARRAY(backingav);

    if(max_fieldix > av_top_index(backingav))
      croak("ARGH: instance does not have a field at index %ld", (long int)max_fieldix);

    while(fieldcount) {
      PADOFFSET padix   = (aux++)->uv;
      UV        fieldix = (aux++)->uv;

      U8 private = fieldix >> FIELDIX_TYPE_SHIFT;
      fieldix &= FIELDIX_MASK;

      bind_field_to_pad(fieldsvs[fieldix], fieldix, private, padix);

      fieldcount--;
    }
  }
#endif

  return PL_op->op_next;
}

OP *ClassPlain_newMETHSTARTOP(pTHX_ U32 flags)
{
#ifdef METHSTART_CONTAINS_FIELD_BINDINGS
  /* We know we're on 5.22 or above, so no worries about assert failures */
  OP *op = newUNOP_AUX(OP_CUSTOM, flags, NULL, NULL);
  op->op_ppaddr = &pp_methstart;
#else
  OP *op = newOP_CUSTOM(&pp_methstart, flags);
#endif
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

  save_clearsv(&PAD_SVl(PADIX_SELF));
  sv_setsv(PAD_SVl(PADIX_SELF), self);

  return PL_op->op_next;
}

OP *ClassPlain_newCOMMONMETHSTARTOP(pTHX_ U32 flags)
{
  OP *op = newOP_CUSTOM(&pp_commonmethstart, flags);
  op->op_private = (U8)(flags >> 8);
  return op;
}

static XOP xop_fieldpad;
static OP *pp_fieldpad(pTHX)
{
#ifdef HAVE_UNOP_AUX
  FIELDOFFSET fieldix = PTR2IV(cUNOP_AUX->op_aux);
#else
  UNOP_with_IV *op = (UNOP_with_IV *)PL_op;
  FIELDOFFSET fieldix = op->iv;
#endif
  PADOFFSET targ = PL_op->op_targ;

  if(SvTYPE(PAD_SV(PADIX_SLOTS)) != SVt_PVAV)
    croak("ARGH: expected ARRAY of slots at PADIX_SLOTS");

  AV *backingav = (AV *)PAD_SV(PADIX_SLOTS);

  if(fieldix > av_top_index(backingav))
    croak("ARGH: instance does not have a field at index %ld", (long int)fieldix);

  bind_field_to_pad(AvARRAY(backingav)[fieldix], fieldix, PL_op->op_private, targ);

  return PL_op->op_next;
}

OP *ClassPlain_newFIELDPADOP(pTHX_ U32 flags, PADOFFSET padix, FIELDOFFSET fieldix)
{
#ifdef HAVE_UNOP_AUX
  OP *op = newUNOP_AUX(OP_CUSTOM, flags, NULL, NUM2PTR(UNOP_AUX_item *, fieldix));
#else
  OP *op = newUNOP_with_IV(OP_CUSTOM, flags, NULL, fieldix);
#endif
  op->op_targ = padix;
  op->op_private = (U8)(flags >> 8);
  op->op_ppaddr = &pp_fieldpad;

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

XS_INTERNAL(xsub_mop_class_seal)
{
  dXSARGS;
  ClassMeta *meta = XSANY.any_ptr;

  PERL_UNUSED_ARG(items);

  if(!PL_parser) {
    /* We need to generate just enough of a PL_parser to keep newSTATEOP()
     * happy, otherwise it will SIGSEGV
     */
    SAVEVPTR(PL_parser);
    Newxz(PL_parser, 1, yy_parser);
    SAVEFREEPV(PL_parser);

    PL_parser->copline = NOLINE;
#if HAVE_PERL_VERSION(5, 20, 0)
    PL_parser->preambling = NOLINE;
#endif
  }

  ClassPlain_mop_class_seal(meta);
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

  enum MetaType type = (enum MetaType)hookdata;

  SV *packagever = args[argi++]->sv;

  SV *superclassname = NULL;

  if(args[argi++]->i) {
    /* extends */
    warn_deprecated("'%s' modifier keyword is deprecated; use :isa() attribute instead", args[argi]->i ? "isa" : "extends");
    argi++; /* ignore the XPK_CHOICE() integer; `extends` and `isa` are synonyms */
    if(type != METATYPE_CLASS)
      croak("Only a class may extend another");

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

    PL_curstash = (HV *)SvREFCNT_inc(meta->stash);
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

    ClassPlain_mop_class_seal(meta);

    LEAVE;

    /* CARGOCULT from perl/perly.y:PACKAGE BAREWORD BAREWORD '{' */
    /* a block is a loop that happens once */
    *out = op_append_elem(OP_LINESEQ,
      newWHILEOP(0, 1, NULL, NULL, body, NULL, 0),
      newSVOP(OP_CONST, 0, &PL_sv_yes));
    return KEYWORD_PLUGIN_STMT;
  }
  else {
    SAVEDESTRUCTOR_X(&ClassPlain_mop_class_seal, meta);

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
    XPK_CHOICE( XPK_LITERAL("extends"), XPK_LITERAL("isa") ), XPK_PACKAGENAME, XPK_VSTRING_OPT
  ),
  /* This should really a repeated (tagged?) choice of a number of things, but
   * right now there's only one thing permitted here anyway
   */
  XPK_ATTRIBUTES,
  {0}
};

static const struct XSParseKeywordHooks kwhooks_class = {
  .permit_hintkey = "Class::Plain/class",
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
  .permit_hintkey = "Class::Plain/field",

  .check = &check_field,

  .pieces = (const struct XSParseKeywordPieceType []){
    XPK_IDENT,
    XPK_ATTRIBUTES,
    {0}
  },
  .build = &build_field,
};
/* We use the method-like keyword parser to parse phaser blocks as well as
 * methods. In order to tell what is going on, hookdata will be an integer
 * set to one of the following
 */

enum PhaserType {
  PHASER_NONE, /* A normal `method`; i.e. not a phaser */
};

static const char *phasertypename[] = {
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
  enum PhaserType type = PTR2UV(hookdata);
  U32 i;
  AV *fields = compclassmeta->direct_fields;
  U32 nfields = av_count(fields);

  if(type != PHASER_NONE)
    /* We need to fool start_subparse() into thinking this is a named function
     * so it emits a real CV and not a protosub
     */
    ctx->actions &= ~XS_PARSE_SUBLIKE_ACTION_CVf_ANON;

  /* Save the methodscope for this subparse, in case of nested methods
   *   (RT132321)
   */
  SAVESPTR(compclassmeta->methodscope);

  /* While creating the new scope CV we need to ENTER a block so as not to
   * break any interpvars
   */
  ENTER;
  SAVESPTR(PL_comppad);
  SAVESPTR(PL_comppad_name);
  SAVESPTR(PL_curpad);

  CV *methodscope = compclassmeta->methodscope = MUTABLE_CV(newSV_type(SVt_PVCV));
  CvPADLIST(methodscope) = pad_new(padnew_SAVE);

  PL_comppad = PadlistARRAY(CvPADLIST(methodscope))[1];
  PL_comppad_name = PadlistNAMES(CvPADLIST(methodscope));
  PL_curpad  = AvARRAY(PL_comppad);

  for(i = 0; i < nfields; i++) {
    FieldMeta *fieldmeta = (FieldMeta *)AvARRAY(fields)[i];

    /* Skip the anonymous ones */
    if(SvCUR(fieldmeta->name) < 2)
      continue;

    /* Claim these are all STATE variables just to quiet the "will not stay
     * shared" warning */
    pad_add_name_sv(fieldmeta->name, padadd_STATE, NULL, NULL);
  }

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

  /* Splice in the field scope CV in */
  CV *methodscope = compclassmeta->methodscope;

  if(CvANON(PL_compcv))
    CvANON_on(methodscope);

  CvOUTSIDE    (methodscope) = CvOUTSIDE    (PL_compcv);
  CvOUTSIDE_SEQ(methodscope) = CvOUTSIDE_SEQ(PL_compcv);

  CvOUTSIDE(PL_compcv) = methodscope;

  if(!compmethodmeta->is_common)
    /* instance method */
    ClassPlain_extend_pad_vars(compclassmeta);
  else {
    /* :common method */
    PADOFFSET padix;

    padix = pad_add_name_pvs("$class", 0, NULL, NULL);
    if(padix != PADIX_SELF)
      croak("ARGH: Expected that padix[$class] = 1");
  }

  intro_my();
}

static void parse_method_pre_blockend(pTHX_ struct XSParseSublikeContext *ctx, void *hookdata)
{
  enum PhaserType type = PTR2UV(hookdata);
  PADNAMELIST *fieldnames = PadlistNAMES(CvPADLIST(compclassmeta->methodscope));
  I32 nfields = av_count(compclassmeta->direct_fields);
  PADNAME **snames = PadnamelistARRAY(fieldnames);
  PADNAME **padnames = PadnamelistARRAY(PadlistNAMES(CvPADLIST(PL_compcv)));

  MethodMeta *compmethodmeta = NUM2PTR(MethodMeta *, SvUV(*hv_fetchs(ctx->moddata, "Class::Plain/compmethodmeta", 0)));

  /* If we have no ctx->body that means this was a bodyless method
   * declaration; a required method
   */
  if(ctx->body && !compmethodmeta->is_common) {
    OP *fieldops = NULL, *methstartop;
#if HAVE_PERL_VERSION(5, 22, 0)
    U32 cop_seq_low = COP_SEQ_RANGE_LOW(padnames[PADIX_SELF]);
#endif

#ifdef METHSTART_CONTAINS_FIELD_BINDINGS
    AV *fieldmap = newAV();
    U32 fieldcount = 0, max_fieldix = 0;

    SAVEFREESV((SV *)fieldmap);
#endif

    {
      ENTER;
      SAVEVPTR(PL_curcop);

      /* See https://rt.cpan.org/Ticket/Display.html?id=132428
       *   https://github.com/Perl/perl5/issues/17754
       */
      PADOFFSET padix;
      for(padix = PADIX_SELF + 1; padix <= PadnamelistMAX(PadlistNAMES(CvPADLIST(PL_compcv))); padix++) {
        PADNAME *pn = padnames[padix];

        if(PadnameIsNULL(pn) || !PadnameLEN(pn))
          continue;

        const char *pv = PadnamePV(pn);
        if(!pv || !strEQ(pv, "$self"))
          continue;

        COP *padcop = NULL;
        if(find_cop_for_lvintro(padix, ctx->body, &padcop))
          PL_curcop = padcop;
        warn("\"my\" variable $self masks earlier declaration in same scope");
      }

      LEAVE;
    }

    fieldops = op_append_list(OP_LINESEQ, fieldops,
      newSTATEOP(0, NULL, NULL));
    fieldops = op_append_list(OP_LINESEQ, fieldops,
      (methstartop = ClassPlain_newMETHSTARTOP(0 |
        (0) |
        (compclassmeta->repr << 8))));

    int i;
    for(i = 0; i < nfields; i++) {
      FieldMeta *fieldmeta = (FieldMeta *)AvARRAY(compclassmeta->direct_fields)[i];
      PADNAME *fieldname = snames[i + 1];

      if(!fieldname
#if HAVE_PERL_VERSION(5, 22, 0)
        /* On perl 5.22 and above we can use PadnameREFCNT to detect which pad
         * slots are actually being used
         */
         || PadnameREFCNT(fieldname) < 2
#endif
        )
          continue;

      FIELDOFFSET fieldix = fieldmeta->fieldix;
      PADOFFSET padix = find_padix_for_field(fieldmeta);

      if(padix == NOT_IN_PAD)
        continue;

      U8 private = 0;

#ifdef METHSTART_CONTAINS_FIELD_BINDINGS
      assert((fieldix & ~FIELDIX_MASK) == 0);
      av_store(fieldmap, padix, newSVuv(((UV)private << FIELDIX_TYPE_SHIFT) | fieldix));
      fieldcount++;
      if(fieldix > max_fieldix)
        max_fieldix = fieldix;
#else
      fieldops = op_append_list(OP_LINESEQ, fieldops,
        /* alias the padix from the field */
        ClassPlain_newFIELDPADOP(private << 8, padix, fieldix));
#endif

#if HAVE_PERL_VERSION(5, 22, 0)
      /* Unshare the padname so the one in the methodscope pad returns to refcount 1 */
      PADNAME *newpadname = newPADNAMEpvn(PadnamePV(fieldname), PadnameLEN(fieldname));
      PadnameREFCNT_dec(padnames[padix]);
      padnames[padix] = newpadname;

      /* Turn off OUTER and set a valid COP sequence range, so the lexical is
       * visible to eval(), PadWalker, perldb, etc.. */
      PadnameOUTER_off(newpadname);
      COP_SEQ_RANGE_LOW(newpadname) = cop_seq_low;
      COP_SEQ_RANGE_HIGH(newpadname) = PL_cop_seqmax;
#endif
    }

#ifdef METHSTART_CONTAINS_FIELD_BINDINGS
    if(fieldcount) {
      UNOP_AUX_item *aux;
      Newx(aux, 2 + fieldcount*2, UNOP_AUX_item);
      cUNOP_AUXx(methstartop)->op_aux = aux;

      (aux++)->uv = fieldcount;
      (aux++)->uv = max_fieldix;

      for(Size_t i = 0; i < av_count(fieldmap); i++) {
        if(!AvARRAY(fieldmap)[i] || !SvOK(AvARRAY(fieldmap)[i]))
          continue;

        (aux++)->uv = i;
        (aux++)->uv = SvUV(AvARRAY(fieldmap)[i]);
      }
    }
#endif
    ctx->body = op_append_list(OP_LINESEQ, fieldops, ctx->body);
  }
  else if(ctx->body && compmethodmeta->is_common) {
    ctx->body = op_append_list(OP_LINESEQ,
      ClassPlain_newCOMMONMETHSTARTOP(0 |
        (compclassmeta->repr << 8)),
      ctx->body);
  }

  compclassmeta->methodscope = NULL;

  /* Restore CvOUTSIDE(PL_compcv) back to where it should be */
  {
    CV *outside = CvOUTSIDE(PL_compcv);
    PADNAMELIST *pnl = PadlistNAMES(CvPADLIST(PL_compcv));
    PADNAMELIST *outside_pnl = PadlistNAMES(CvPADLIST(outside));

    /* Lexical captures will need their parent pad index fixing
     * Technically these only matter for CvANON because they're only used when
     * reconstructing the parent pad captures by OP_ANONCODE. But we might as
     * well be polite and fix them for all CVs
     */
    PADOFFSET padix;
    for(padix = 1; padix <= PadnamelistMAX(pnl); padix++) {
      PADNAME *pn = PadnamelistARRAY(pnl)[padix];
      if(PadnameIsNULL(pn) ||
         !PadnameOUTER(pn) ||
         !PARENT_PAD_INDEX(pn))
        continue;

      PADNAME *outside_pn = PadnamelistARRAY(outside_pnl)[PARENT_PAD_INDEX(pn)];

      PARENT_PAD_INDEX_set(pn, PARENT_PAD_INDEX(outside_pn));
      if(!PadnameOUTER(outside_pn))
        PadnameOUTER_off(pn);
    }

    CvOUTSIDE(PL_compcv)     = CvOUTSIDE(outside);
    CvOUTSIDE_SEQ(PL_compcv) = CvOUTSIDE_SEQ(outside);
  }

  if(type != PHASER_NONE)
    /* We need to remove the name now to stop newATTRSUB() from creating this
     * as a named symbol table entry
     */
    ctx->actions &= ~XS_PARSE_SUBLIKE_ACTION_INSTALL_SYMBOL;
}

static void parse_method_post_newcv(pTHX_ struct XSParseSublikeContext *ctx, void *hookdata)
{
  enum PhaserType type = PTR2UV(hookdata);

  MethodMeta *compmethodmeta;
  {
    SV *tmpsv = *hv_fetchs(ctx->moddata, "Class::Plain/compmethodmeta", 0);
    compmethodmeta = NUM2PTR(MethodMeta *, SvUV(tmpsv));
    sv_setuv(tmpsv, 0);
  }

  if(ctx->cv)
    CvMETHOD_on(ctx->cv);

  switch(type) {
    case PHASER_NONE:
      if(ctx->cv && ctx->name && (ctx->actions & XS_PARSE_SUBLIKE_ACTION_INSTALL_SYMBOL)) {
        MethodMeta *meta = ClassPlain_mop_class_add_method(compclassmeta, ctx->name);

        meta->is_common = compmethodmeta->is_common;
      }
      break;

  }

  SV **varnamep;
  if((varnamep = hv_fetchs(ctx->moddata, "Class::Plain/method_varname", 0))) {
    PADOFFSET padix = pad_add_name_sv(*varnamep, 0, NULL, NULL);
    intro_my();

    SV **svp = &PAD_SVl(padix);

    if(*svp)
      SvREFCNT_dec(*svp);

    *svp = newRV_inc((SV *)ctx->cv);
    SvREADONLY_on(*svp);
  }

  if(type != PHASER_NONE)
    /* Do not generate REFGEN/ANONCODE optree, do not yield expression */
    ctx->actions &= ~(XS_PARSE_SUBLIKE_ACTION_REFGEN_ANONCODE|XS_PARSE_SUBLIKE_ACTION_RET_EXPR);

  SvREFCNT_dec(compmethodmeta->name);
  Safefree(compmethodmeta);
}

static struct XSParseSublikeHooks parse_method_hooks = {
  .flags           = XS_PARSE_SUBLIKE_FLAG_FILTERATTRS |
                     XS_PARSE_SUBLIKE_COMPAT_FLAG_DYNAMIC_ACTIONS |
                     XS_PARSE_SUBLIKE_FLAG_BODY_OPTIONAL,
  .permit_hintkey  = "Class::Plain/method",
  .permit          = parse_method_permit,
  .pre_subparse    = parse_method_pre_subparse,
  .filter_attr     = parse_method_filter_attr,
  .post_blockstart = parse_method_post_blockstart,
  .pre_blockend    = parse_method_pre_blockend,
  .post_newcv      = parse_method_post_newcv,
};

static struct XSParseSublikeHooks parse_phaser_hooks = {
  .flags           = XS_PARSE_SUBLIKE_COMPAT_FLAG_DYNAMIC_ACTIONS,
  .skip_parts      = XS_PARSE_SUBLIKE_PART_NAME|XS_PARSE_SUBLIKE_PART_ATTRS,
  /* no permit */
  .pre_subparse    = parse_method_pre_subparse,
  .post_blockstart = parse_method_post_blockstart,
  .pre_blockend    = parse_method_pre_blockend,
  .post_newcv      = parse_method_post_newcv,
};

static int parse_phaser(pTHX_ OP **out, void *hookdata)
{
  if(!have_compclassmeta)
    croak("Cannot '%s' outside of 'class'", phasertypename[PTR2UV(hookdata)]);

  lex_read_space(0);

  return xs_parse_sublike(&parse_phaser_hooks, hookdata, out);
}

#ifdef HAVE_DMD_HELPER
static void dump_fieldmeta(pTHX_ DMDContext *ctx, FieldMeta *fieldmeta)
{
  DMD_DUMP_STRUCT(ctx, "Class::Plain/FieldMeta", fieldmeta, sizeof(FieldMeta),
    6, ((const DMDNamedField []){
      {"the name SV",          DMD_FIELD_PTR,  .ptr = fieldmeta->name},
      {"the class",            DMD_FIELD_PTR,  .ptr = fieldmeta->class},
      {"the default value SV", DMD_FIELD_PTR,  .ptr = ClassPlain_mop_field_get_default_sv(fieldmeta)},
      /* TODO: Maybe hunt for constants in the defaultexpr optree fragment? */
      {"fieldix",              DMD_FIELD_UINT, .n   = fieldmeta->fieldix},
      {"the :param name SV",   DMD_FIELD_PTR,  .ptr = fieldmeta->paramname},
      {"the hooks AV",         DMD_FIELD_PTR,  .ptr = fieldmeta->hooks},
    })
  );
}

static void dump_methodmeta(pTHX_ DMDContext *ctx, MethodMeta *methodmeta)
{
  DMD_DUMP_STRUCT(ctx, "Class::Plain/MethodMeta", methodmeta, sizeof(MethodMeta),
    4, ((const DMDNamedField []){
      {"the name SV",     DMD_FIELD_PTR,  .ptr = methodmeta->name},
      {"the class",       DMD_FIELD_PTR,  .ptr = methodmeta->class},
      {"is_common",       DMD_FIELD_BOOL, .b   = methodmeta->is_common},
    })
  );
}

static void dump_adjustblock(pTHX_ DMDContext *ctx, AdjustBlock *adjustblock)
{
  DMD_DUMP_STRUCT(ctx, "Class::Plain/AdjustBlock", adjustblock, sizeof(AdjustBlock),
    2, ((const DMDNamedField []){
      {"the CV",          DMD_FIELD_PTR,  .ptr = adjustblock->cv},
    })
  );
}

static void dump_classmeta(pTHX_ DMDContext *ctx, ClassMeta *classmeta)
{
  /* We'll handle the two types of classmeta by claiming two different struct
   * types
   */

#define N_COMMON_FIELDS 16
#define COMMON_FIELDS \
      {"type",                       DMD_FIELD_U8,   .n   = classmeta->type},            \
      {"repr",                       DMD_FIELD_U8,   .n   = classmeta->repr},            \
      {"sealed",                     DMD_FIELD_BOOL, .b   = classmeta->sealed},          \
      {"start_fieldix",              DMD_FIELD_UINT, .n   = classmeta->start_fieldix},   \
      {"the name SV",                DMD_FIELD_PTR,  .ptr = classmeta->name},            \
      {"the stash SV",               DMD_FIELD_PTR,  .ptr = classmeta->stash},           \
      {"the pending submeta AV",     DMD_FIELD_PTR,  .ptr = classmeta->pending_submeta}, \
      {"the hooks AV",               DMD_FIELD_PTR,  .ptr = classmeta->hooks},           \
      {"the direct fields AV",       DMD_FIELD_PTR,  .ptr = classmeta->direct_fields},   \
      {"the direct methods AV",      DMD_FIELD_PTR,  .ptr = classmeta->direct_methods},  \
      {"the param map HV",           DMD_FIELD_PTR,  .ptr = classmeta->parammap},        \
      {"the requiremethods AV",      DMD_FIELD_PTR,  .ptr = classmeta->requiremethods},  \
      {"the initfields CV",          DMD_FIELD_PTR,  .ptr = classmeta->initfields},      \
      {"the ADJUST blocks AV",       DMD_FIELD_PTR,  .ptr = classmeta->adjustblocks},    \
      {"the temporary method scope", DMD_FIELD_PTR,  .ptr = classmeta->methodscope}

  switch(classmeta->type) {
    case METATYPE_CLASS:
      DMD_DUMP_STRUCT(ctx, "Class::Plain/ClassMeta.class", classmeta, sizeof(ClassMeta),
        N_COMMON_FIELDS+5, ((const DMDNamedField []){
          COMMON_FIELDS,
          {"the supermeta",                         DMD_FIELD_PTR, .ptr = classmeta->cls.supermeta},
          {"the foreign superclass constructor CV", DMD_FIELD_PTR, .ptr = classmeta->cls.foreign_new},
          {"the foreign superclass DOES CV",        DMD_FIELD_PTR, .ptr = classmeta->cls.foreign_does},
        })
      );
      break;
  }

#undef COMMON_FIELDS

  I32 i;

  for(i = 0; i < av_count(classmeta->direct_fields); i++) {
    FieldMeta *fieldmeta = (FieldMeta *)AvARRAY(classmeta->direct_fields)[i];

    dump_fieldmeta(aTHX_ ctx, fieldmeta);
  }

  for(i = 0; i < av_count(classmeta->direct_methods); i++) {
    MethodMeta *methodmeta = (MethodMeta *)AvARRAY(classmeta->direct_methods)[i];

    dump_methodmeta(aTHX_ ctx, methodmeta);
  }

  for(i = 0; classmeta->adjustblocks && i < av_count(classmeta->adjustblocks); i++) {
    AdjustBlock *adjustblock = (AdjustBlock *)AvARRAY(classmeta->adjustblocks)[i];

    dump_adjustblock(aTHX_ ctx, adjustblock);
  }
}

static int dumppackage_class(pTHX_ DMDContext *ctx, const SV *sv)
{
  int ret = 0;

  ClassMeta *meta = NUM2PTR(ClassMeta *, SvUV((SV *)sv));

  dump_classmeta(aTHX_ ctx, meta);

  ret += DMD_ANNOTATE_SV(sv, (SV *)meta, "the Class::Plain class");

  return ret;
}
#endif

struct CustomFieldHookData
{
  SV *apply_cb;
};

/* internal function shared by various *.c files */
void ClassPlain__need_PLparser(pTHX)
{
  if(!PL_parser) {
    /* We need to generate just enough of a PL_parser to keep newSTATEOP()
     * happy, otherwise it will SIGSEGV (RT133258)
     */
    SAVEVPTR(PL_parser);
    Newxz(PL_parser, 1, yy_parser);
    SAVEFREEPV(PL_parser);

    PL_parser->copline = NOLINE;
#if HAVE_PERL_VERSION(5, 20, 0)
    PL_parser->preambling = NOLINE;
#endif
  }
}

MODULE = Class::Plain    PACKAGE = Class::Plain::MetaFunctions

BOOT:
  XopENTRY_set(&xop_methstart, xop_name, "methstart");
  XopENTRY_set(&xop_methstart, xop_desc, "enter method");
#ifdef METHSTART_CONTAINS_FIELD_BINDINGS
  XopENTRY_set(&xop_methstart, xop_class, OA_UNOP_AUX);
#else
  XopENTRY_set(&xop_methstart, xop_class, OA_BASEOP);
#endif
  Perl_custom_op_register(aTHX_ &pp_methstart, &xop_methstart);

  XopENTRY_set(&xop_commonmethstart, xop_name, "commonmethstart");
  XopENTRY_set(&xop_commonmethstart, xop_desc, "enter method :common");
  XopENTRY_set(&xop_commonmethstart, xop_class, OA_BASEOP);
  Perl_custom_op_register(aTHX_ &pp_commonmethstart, &xop_commonmethstart);

  XopENTRY_set(&xop_fieldpad, xop_name, "fieldpad");
  XopENTRY_set(&xop_fieldpad, xop_desc, "fieldpad()");
#ifdef HAVE_UNOP_AUX
  XopENTRY_set(&xop_fieldpad, xop_class, OA_UNOP_AUX);
#else
  XopENTRY_set(&xop_fieldpad, xop_class, OA_UNOP); /* technically a lie */
#endif
  Perl_custom_op_register(aTHX_ &pp_fieldpad, &xop_fieldpad);

  boot_xs_parse_keyword(0.22); /* XPK_AUTOSEMI */

  register_xs_parse_keyword("class", &kwhooks_class, (void *)METATYPE_CLASS);
  register_xs_parse_keyword("field", &kwhooks_field, "field");
  register_xs_parse_keyword("has",   &kwhooks_field,   "has");

  boot_xs_parse_sublike(0.15); /* dynamic actions */

  register_xs_parse_sublike("method", &parse_method_hooks, (void *)PHASER_NONE);

  ClassPlain__boot_classes(aTHX);
  ClassPlain__boot_fields(aTHX);
  
  
