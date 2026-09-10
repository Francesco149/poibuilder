#ifndef PSP_PROF_H
#define PSP_PROF_H

#include "pbm_loader.h"

/* Runs the on-device profiling suite and writes ms0:/poi_profile.txt.
 * Call from the frame path before entering the interactive loop. */
void psp_prof_suite(PbmMap* map);

#endif /* PSP_PROF_H */
