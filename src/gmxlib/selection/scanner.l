/*
 *
 *                This source code is part of
 *
 *                 G   R   O   M   A   C   S
 *
 *          GROningen MAchine for Chemical Simulations
 *
 * Written by David van der Spoel, Erik Lindahl, Berk Hess, and others.
 * Copyright (c) 1991-2000, University of Groningen, The Netherlands.
 * Copyright (c) 2001-2009, The GROMACS development team,
 * check out http://www.gromacs.org for more information.

 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * If you want to redistribute modifications, please consider that
 * scientific software is very special. Version control is crucial -
 * bugs must be traceable. We will be happy to consider code for
 * inclusion in the official distribution, but derived work must not
 * be called official GROMACS. Details are found in the README & COPYING
 * files - if they are missing, get the official version at www.gromacs.org.
 *
 * To help us fund GROMACS development, we humbly ask that you cite
 * the papers on the package - you can find them in the top README file.
 *
 * For more info, check our website at http://www.gromacs.org
 */
/*! \cond \internal \file scanner.l
 * \brief
 * Tokenizer for the selection language.
 * \endcond
 */
/*! \internal \file scanner.c
 * \brief
 * Generated (from scanner.l by Flex) tokenizer for the selection language.
 */
%{
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <math.h>

#include <smalloc.h>
#include <string2.h>

#include <selmethod.h>

#include "parsetree.h"
#include "selcollection.h"
#include "selelem.h"
#include "symrec.h"

#include "parser.h"
#include "scanner.h"

#define DEFAULT_PROMPT     ">"
#define CONTINUE_PROMPT    "..."
#define STRSTORE_ALLOCSTEP 1000

typedef struct gmx_sel_lexer_t
{
    struct gmx_ana_selcollection_t *sc;
    bool                  bPrompt;
    const char           *prompt;

    char                **strstore;
    int                   slen;
    int                   nalloc_str;

    char                 *pselstr;
    int                   pslen;
    int                   nalloc_psel;

    gmx_ana_selmethod_t **mstack;
    int                   msp;
    int                   mstack_alloc;
    int                   neom;
    gmx_ana_selparam_t   *nextparam;

    bool                  bMatchOf;
    bool                  bCmdStart;

    bool                  bBuffer;
    YY_BUFFER_STATE       buffer;
} gmx_sel_lexer_t;

#define YY_EXTRA_TYPE gmx_sel_lexer_t *

/* Because Flex defines yylval, yytext, and yyleng as macros,
 * we cannot have them here as parameter names... */
static int
process_next_param(YYSTYPE *, gmx_sel_lexer_t *state);
static int
process_identifier(YYSTYPE *, char *, int,
                   gmx_sel_lexer_t *state);
static void
add_token(const char *str, int len, gmx_sel_lexer_t *state);

#define ADD_TOKEN add_token(yytext, yyleng, state)

#define YY_INPUT(buf,result,max_size) \
    { \
        gmx_sel_lexer_t *state = yyget_extra(yyscanner); \
        int c = '*', n; \
        if (state->bPrompt) \
        { \
            fprintf(stderr, "%s ", state->prompt); \
            state->bPrompt = FALSE; \
        } \
        for (n = 0; n < max_size && \
                    (c = getc(yyin)) != EOF && c != '\n'; ++n) \
        { \
            buf[n] = (char)c; \
        } \
        if (c == '\n') \
        { \
            buf[n++] = (char)c; \
            if (state->prompt) \
            { \
                state->prompt  = DEFAULT_PROMPT; \
                state->bPrompt = TRUE; \
            } \
        } \
        if (c == EOF && ferror(yyin)) \
        { \
            YY_FATAL_ERROR("input in flex scanner failed"); \
        } \
        result = n; \
        if (state->strstore) \
        { \
            while (n > state->nalloc_str - state->slen) \
            { \
                state->nalloc_str += STRSTORE_ALLOCSTEP; \
                srenew(*state->strstore, state->nalloc_str); \
            } \
            strncpy((*state->strstore)+state->slen, buf, n); \
            state->slen += n; \
            if (state->nalloc_str > 0) \
            { \
                (*state->strstore)[state->slen] = 0; \
            } \
        } \
    }
%}

INTEGER    [[:digit:]]+
DSEQ       ([[:digit:]]+)
FRAC       (([[:digit:]]*"."{DSEQ})|{DSEQ}".")
EXP        ([eE][+-]?{DSEQ})
REAL       ("-"?(({FRAC}{EXP}?)|({DSEQ}{EXP})))
STRING     (\"([^\"\\\n]|(\\\"))*\")
IDENTIFIER ([[:alpha:]][_[:alnum:]]*)
CMPOP      (([<>]=?)|([!=]=))
COMMENT    (#.*)

%option nodefault
%option noyywrap
%option reentrant
%option prefix="_gmx_sel_yy"

%s matchof
%s cmdstart
%x help

%%

%{
    gmx_sel_lexer_t *state = yyget_extra(yyscanner);
    /* Return END_OF_METHOD/PARAM_* immediately if necessary */
    if (state->nextparam)
    {
        return process_next_param(yylval, state);
    }
    /* Handle the start conditions for 'of' matching */
    if (state->bMatchOf)
    {
        BEGIN(matchof);
        state->bMatchOf = FALSE;
    }
    else if (state->bCmdStart)
    {
        BEGIN(cmdstart);
        state->bCmdStart = FALSE;
    }
    else if (YYSTATE != help)
    {
        BEGIN(0);
    }
%}

{COMMENT}
{INTEGER}       { yylval->i   = strtol(yytext, NULL, 10);    ADD_TOKEN; return INT;  }
{REAL}          { yylval->r   = strtod(yytext, NULL);        ADD_TOKEN; return REAL; }
{STRING}        { yylval->str = strndup(yytext+1, yyleng-2); ADD_TOKEN; return STR;  }

\\\n            { if (state->prompt) state->prompt = CONTINUE_PROMPT; }
";"|\n          {
                    if (yytext[0] == ';' || state->prompt)
                    {
                        state->bCmdStart = TRUE;
                        return CMD_SEP;
                    }
                }
<cmdstart>help  { BEGIN(help); return HELP; }
<help>{
[[:blank:]]+
{IDENTIFIER}    { yylval->str = strndup(yytext, yyleng); return HELP_TOPIC; }
";"|\n          { state->bCmdStart = TRUE; return CMD_SEP; }
.               { return INVALID; }
}
group           { ADD_TOKEN; return GROUP; }
to              { ADD_TOKEN; return TO; }
<matchof>of     { ADD_TOKEN; BEGIN(0); return OF; }
and|"&&"        { ADD_TOKEN; return AND; }
or|"||"         { ADD_TOKEN; return OR; }
xor             { ADD_TOKEN; return XOR; }
not|"!"         { ADD_TOKEN; return NOT; }
{CMPOP}         { yylval->str = strndup(yytext, yyleng); ADD_TOKEN; return CMP_OP; }

{IDENTIFIER}    { return process_identifier(yylval, yytext, yyleng, state); }

[[:blank:]]+    { add_token(" ", 1, state); }
[_[:alnum:]]+   { yylval->str = strndup(yytext, yyleng); ADD_TOKEN; return STR; }
.               { add_token(yytext, 1, state); return yytext[0]; }

%%
/* Undefine the macros so that we can have them as variable names in the
 * subroutines.
 * There are other ways of doing this, but this is probably the easiest. */
#undef yylval
#undef yytext
#undef yyleng

static int
process_next_param(YYSTYPE *yylval, gmx_sel_lexer_t *state)
{
    gmx_ana_selparam_t *param = state->nextparam;

    if (state->neom > 0)
    {
        --state->neom;
        return END_OF_METHOD;
    }
    state->nextparam = NULL;
    /* FIXME: The constness should not be cast away */
    yylval->str = (char *)param->name;
    add_token(param->name, -1, state);
    switch (param->val.type)
    {
        case NO_VALUE:    return PARAM_BOOL;
        case INT_VALUE:   return PARAM_INT;
        case REAL_VALUE:  return PARAM_REAL;
        case STR_VALUE:   return PARAM_STR;
        case POS_VALUE:   return PARAM_POS;
        case GROUP_VALUE: return PARAM_GROUP;
    }
    return INVALID; /* Should not be reached */
}

static int
process_identifier(YYSTYPE *yylval, char *yytext, int yyleng,
                   gmx_sel_lexer_t *state)
{
    gmx_sel_symrec_t *symbol;
    e_symbol_t        symtype;

    /* Check if the identifier matches with a parameter name */
    if (state->msp >= 0)
    {
        gmx_ana_selparam_t *param = NULL;
        int                 sp = state->msp;
        while (!param && sp >= 0)
        {
            int             i;
            for (i = 0; i < state->mstack[sp]->nparams; ++i)
            {
                if (state->mstack[sp]->param[i].name == NULL)
                {
                    continue;
                }
                if (!strncmp(state->mstack[sp]->param[i].name, yytext, yyleng))
                {
                    param = &state->mstack[sp]->param[i];
                    break;
                }
            }
            if (!param)
            {
                --sp;
            }
        }
        if (param)
        {
            if (sp < state->msp)
            {
                state->neom = state->msp - sp - 1;
                state->nextparam = param;
                return END_OF_METHOD;
            }
            /* FIXME: The constness should not be cast away */
            yylval->str = (char *)param->name;
            add_token(param->name, -1, state);
            switch (param->val.type)
            {
                case NO_VALUE:    return PARAM_BOOL;
                case INT_VALUE:   return PARAM_INT;
                case REAL_VALUE:  return PARAM_REAL;
                case STR_VALUE:   return PARAM_STR;
                case POS_VALUE:   return PARAM_POS;
                case GROUP_VALUE: return PARAM_GROUP;
            }
            return INVALID; /* Should not be reached */
        }
    }

    /* Check if the identifier matches with a symbol */
    symbol = _gmx_sel_find_symbol_len(state->sc->symtab, yytext, yyleng, FALSE);
    /* If there is no match, return the token as a string */
    if (!symbol)
    {
        yylval->str = strndup(yytext, yyleng);
        ADD_TOKEN;
        return IDENTIFIER;
    }
    add_token(_gmx_sel_sym_name(symbol), -1, state);
    symtype = _gmx_sel_sym_type(symbol);
    /* Reserved symbols should have been caught earlier */
    if (symtype == SYMBOL_RESERVED)
    {
        return INVALID;
    }
    /* For variable symbols, return the type of the variable value */
    if (symtype == SYMBOL_VARIABLE)
    {
        t_selelem *var;

        var = _gmx_sel_sym_value_var(symbol);
        /* Return simple tokens for constant variables */
        if (var->type == SEL_CONST)
        {
            switch (var->v.type)
            {
                case INT_VALUE:
                    yylval->i = var->v.u.i[0];
                    return INT;
                case REAL_VALUE:
                    yylval->r = var->v.u.r[0];
                    return REAL;
                case POS_VALUE:
                    break;
                default:
                    return INVALID;
            }
        }
        yylval->sel = var;
        switch (var->v.type)
        {
            case INT_VALUE:   return VARIABLE_NUMERIC;
            case REAL_VALUE:  return VARIABLE_NUMERIC;
            case POS_VALUE:   return VARIABLE_POS;
            case GROUP_VALUE: return VARIABLE_GROUP;
            default:          return INVALID;
        }
        return INVALID;
    }
    /* For method symbols, return the correct type */
    if (symtype == SYMBOL_METHOD)
    {
        gmx_ana_selmethod_t *method;

        method = _gmx_sel_sym_value_method(symbol);
        yylval->meth = method;
        if (!(method->flags & SMETH_MODIFIER) && method->nparams == 0)
        {
            /* Keyword */
            switch (method->type)
            {
                case INT_VALUE:   return KEYWORD_INT;
                case REAL_VALUE:  return KEYWORD_REAL;
                case STR_VALUE:   return KEYWORD_STR;
                case GROUP_VALUE: return KEYWORD_GROUP;
                default:          return INVALID;
            }
        } else {
            /* Method with parameters or a modifier */
            if (method->flags & SMETH_MODIFIER)
            {
                /* Remove all methods from the stack */
                state->msp = -1;
                if (method->param[1].name == NULL)
                {
                    state->nextparam = &method->param[1];
                }
            }
            else
            {
                if (method->param[0].name == NULL)
                {
                    state->nextparam = &method->param[0];
                }
            }
            ++state->msp;
            if (state->msp >= state->mstack_alloc)
            {
                state->mstack_alloc += 10;
                srenew(state->mstack, state->mstack_alloc);
            }
            state->mstack[state->msp] = method;
            if (method->flags & SMETH_MODIFIER)
            {
                return MODIFIER;
            }
            switch (method->type)
            {
                case INT_VALUE:   return METHOD_NUMERIC;
                case REAL_VALUE:  return METHOD_NUMERIC;
                case POS_VALUE:   return METHOD_POS;
                case GROUP_VALUE: return METHOD_GROUP;
                default:
                    --state->msp;
                    return INVALID;
            }
        }
    }
    /* For position symbols, we need to return KEYWORD_POS, but we also need
     * some additional handling. */
    if (symtype == SYMBOL_POS)
    {
        state->bMatchOf = TRUE;
        yylval->str = _gmx_sel_sym_name(symbol);
        return KEYWORD_POS;
    }
    /* Should not be reached */
    return INVALID;
}

static void
add_token(const char *str, int len, gmx_sel_lexer_t *state)
{
    if (!str || len == 0 || strlen(str) == 0)
    {
        return;
    }
    if (len < 0)
    {
        len = strlen(str);
    }
    /* Allocate more memory if necessary */
    if (state->nalloc_psel - state->pslen < len)
    {
        int incr = STRSTORE_ALLOCSTEP < len ? len : STRSTORE_ALLOCSTEP;
        state->nalloc_psel += incr;
        srenew(state->pselstr, state->nalloc_psel);
    }
    /* Append the token to the stored string */
    strncpy(state->pselstr + state->pslen, str, len);
    state->pslen += len;
    state->pselstr[state->pslen] = 0;
}

int
_gmx_sel_init_lexer(yyscan_t *scannerp, struct gmx_ana_selcollection_t *sc,
                    bool bInteractive)
{
    gmx_sel_lexer_t *state;
    int              rc;

    rc = yylex_init(scannerp);
    if (rc != 0)
    {
        return rc;
    }

    snew(state, 1);
    state->sc        = sc;
    state->bPrompt   = bInteractive;
    state->prompt    = bInteractive ? DEFAULT_PROMPT : NULL;

    state->strstore  = &sc->selstr;
    if (sc->selstr)
    {
        state->slen       = strlen(sc->selstr);
        state->nalloc_str = state->slen + 1;
    }
    else
    {
        state->slen       = 0;
        state->nalloc_str = 0;
    }

    snew(state->pselstr, STRSTORE_ALLOCSTEP);
    state->pselstr[0]   = 0;
    state->pslen        = 0;
    state->nalloc_psel  = STRSTORE_ALLOCSTEP;

    snew(state->mstack, 20);
    state->mstack_alloc = 20;
    state->msp          = -1;
    state->neom         = 0;
    state->nextparam    = NULL;
    state->bMatchOf     = FALSE;
    state->bCmdStart    = TRUE;
    state->bBuffer      = FALSE;

    yyset_extra(state, *scannerp);
    return 0;
}

void
_gmx_sel_free_lexer(yyscan_t scanner)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);

    sfree(state->pselstr);
    sfree(state->mstack);
    if (state->bBuffer)
    {
        yy_delete_buffer(state->buffer, scanner);
    }
    sfree(state);
    yylex_destroy(scanner);
}

bool
_gmx_sel_is_lexer_interactive(yyscan_t scanner)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);
    return state->bPrompt;
}

struct gmx_ana_selcollection_t *
_gmx_sel_lexer_selcollection(yyscan_t scanner)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);
    return state->sc;
}

const char *
_gmx_sel_lexer_pselstr(yyscan_t scanner)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);
    return state->pselstr;
}

void
_gmx_sel_lexer_clear_pselstr(yyscan_t scanner)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);
    state->pselstr[0] = 0;
    state->pslen      = 0;
}

void
_gmx_sel_finish_method(yyscan_t scanner)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);

    if (state->msp >= 0)
    {
        --state->msp;
    }
}

void
_gmx_sel_set_lex_input_file(yyscan_t scanner, FILE *fp)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);

    state->bBuffer = TRUE;
    state->buffer  = yy_create_buffer(fp, YY_BUF_SIZE, scanner);
    yy_switch_to_buffer(state->buffer, scanner);
}

void
_gmx_sel_set_lex_input_str(yyscan_t scanner, const char *str)
{
    gmx_sel_lexer_t *state = yyget_extra(scanner);

    state->bBuffer = TRUE;
    state->buffer  = yy_scan_string(str, scanner);
    /* Append the buffer to the string store as YY_INPUT is not called */
    if (state->strstore)
    {
        int len, slen;

        if (*state->strstore)
        {
            slen = strlen(*state->strstore);
        }
        else
        {
            slen = 0;
        }
        len = strlen(str);
        snew(*state->strstore, len + slen + 1);
        strcpy((*state->strstore)+slen, str);
    }
}