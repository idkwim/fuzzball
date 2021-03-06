/*
** translate.h
** 
** Made by David Brumley
** 
** Started on  Tue Apr 24 14:51:16 2007 David Brumley
** Last update Wed Jun 27 17:48:32 2007 David Brumley
*/

#ifndef   	TRANSLATE_H_
#define   	TRANSLATE_H_

#ifdef __cplusplus
#include <vector>
#include "asm_program.h"
#include "stmt.h"
#include "exp.h"
#include "common.h"
#include "irtoir.h"

using namespace std;

typedef struct instmap_s {
  asm_program_t *prog;
  map<address_t, Instruction *> imap;
} instmap_t;

#else
typedef struct _instmap_t instmap_t;

#endif // __cplusplus

typedef struct _cflow_t { int ctype; address_t target; } cflow_t;


#ifdef __cplusplus
extern "C" {
#endif

   extern asm_program_t *instmap_to_asm_program(instmap_t *map);

  extern instmap_t * filename_to_instmap(const char *filename);

  extern vine_blocks_t *instmap_translate_address_range(instmap_t *insts,
							address_t start,
							address_t end);

  extern vine_block_t *instmap_translate_address(instmap_t *insts,
						 address_t addr);

  extern int instmap_has_address(instmap_t *insts,
				 address_t addr);

  extern cflow_t *instmap_control_flow_type(instmap_t *insts,
					    address_t addr);
  extern address_t get_last_segment_address(const char *filename, 
					    address_t addr);


#ifdef __cplusplus
}
#endif

#endif 	    /* !TRANSLATE_H_ */
