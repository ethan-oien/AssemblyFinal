; the file that stores the initial state
%define BOARD_FILE 'board.txt'
%define BEATMAP_FILE 'beatmap.txt'
%define BEATMAP_OUT_FILE 'beatmapnew.txt'

; how to represent everything
%define WALL_CHAR '#'
%define PLAYER_CHAR 'O'

; the size of the game screen in characters
%define HEIGHT 30
%define WIDTH 13
%define HITHEIGHT 22
%define HITRANGE 1

; the player starting position.
; top left is considered (0,0)
%define STARTX 2
%define STARTY 0

; these keys do things
%define EXITCHAR 'x'
%define GCHAR 's'
%define RCHAR 'd'
%define YCHAR 'f'
%define BCHAR 'j'
%define OCHAR 'k'

; magic values for nonblocking getchar
%define TICK 100000     ; 1/10th of a second
;%define TICK 500000    ; 1/10th of a second
%define F_GETFL 3
%define F_SETFL 4
%define O_NONBLOCK 2048
%define STDIN 0

; max amount of notes
%define MAXNOTES 0xffff

segment .data

        ; used to fopen() the board file defined above
        board_file                      db BOARD_FILE,0
        beatmap_file            db BEATMAP_FILE,0
        beatmap_out_file        db BEATMAP_OUT_FILE,0

        ; used to change the terminal mode
        mode_r                          db "r",0
        mode_w                          db "w",0
        raw_mode_on_cmd         db "stty raw -echo",0
        raw_mode_off_cmd        db "stty -raw echo",0

        ; called by system() to clear/refresh the screen
        clear_screen_cmd        db "clear",0

        ; things the program will print
        help_str                        db 13,10,"Controls: ", \
                                                        GCHAR,"=GREEN / ", \
                                                        RCHAR,"=RED / ", \
                                                        YCHAR,"=YELLOW / ", \
                                                        BCHAR,"=BLUE / ", \
                                                        OCHAR,"=ORANGE / ", \
                                                        EXITCHAR,"=EXIT", \
                                                        13,10,10,0

        ; colors
        color_default           db 27,"[0m",0
        color_dim                       db 27,"[2m",0
        color_bold                      db 27,"[1m",0
        color_green                     db 27,"[92m",0
        color_red                       db 27,"[91m",0
        color_yellow            db 27,"[93m",0
        color_blue                      db 27,"[94m",0
        color_orange            db 27,"[95m",0

        ; point information
        ptsfmt                          db "     Points: %d", 0
        mulfmt                          db " Multiplier: %d", 0

        ; debug
        debugmode                       dd 0
        debug                           db "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",0
        shtdbg                          db "fff",0x0d,0x0a,0
        strfmt                          db "%d %d %d %d %d ", 0
        debugstr                        db "-debug", 0

        ; create
        createmode                      dd 0
        createstr                       db "-create", 0
        crtfmt                          db "%c", 0

segment .bss

        ; this array stores the current rendered gameboard (HxW)
        board   resb    (HEIGHT * WIDTH)
        notes   resd    MAXNOTES
        numnote resd    1

        ; these variables store point data
        multi   resd    1
        points  resd    1

        ; these variables store the current beatmap
        ypos    resd    1

        ; debug
        ndebug  resd    5

segment .text

        global  main
        global  raw_mode_on
        global  raw_mode_off
        global  init_board
        global  render

        extern  printf
        extern  strncmp
        extern  tolower
        extern  fscanf
        extern  fcntl
        extern  usleep
        extern  system
        extern  putchar
        extern  getchar
        extern  fopen
        extern  fread
        extern  fgetc
        extern  fclose
        extern  fprintf

main:
        enter   0,0
        pusha
        ;***************CODE STARTS HERE***************************

        cmp     DWORD [ebp+8], 2
        jl      noargs

                xor ecx, ecx
                argsloop:
                cmp     ecx, DWORD [ebp+8]
                jge     argsloopend

                        mov     eax, DWORD [ebp+12]
                        mov     eax, DWORD [eax+ecx*4]

                        push    ecx
                        push    10
                        push    debugstr
                        push    eax
                        call    strncmp
                        add     esp, 12
                        pop     ecx

                        cmp     eax, 0
                        jne     nodebugmode
                                mov     DWORD [debugmode], 1
                        nodebugmode:

                        mov     eax, DWORD [ebp+12]
                        mov     eax, DWORD [eax+ecx*4]

                        push    ecx
                        push    10
                        push    createstr
                        push    eax
                        call    strncmp
                        add     esp, 12
                        pop     ecx

                        cmp     eax, 0
                        jne     nocreatemode
                                mov     DWORD [createmode], 1
                        nocreatemode:

                inc     ecx
                jmp     argsloop
                argsloopend:

        noargs:

        ; default debug information
        call    resetdebug

        ; put the terminal in raw mode so the game works nicely
        call    raw_mode_on

        ; read the game board file into the global variable
        call    init_board

        cmp     DWORD [createmode], 1
        jne     nocreateinit
                mov     DWORD [numnote], MAXNOTES

                xor     eax, eax
                initcreatefor:
                cmp     eax, DWORD [numnote]
                jge     initcreateforend

                        mov     DWORD [notes+eax*4], 0

                inc     eax
                jmp     initcreatefor
                initcreateforend:

                jmp     createinitend
        nocreateinit:
                call    init_notes
        createinitend:

        ; set the player at the proper start position
        cmp     DWORD [createmode], 1
        je      yescreate2
                mov     eax, DWORD [numnote]
                neg     eax
                mov             DWORD [ypos], eax
                jmp     endyescreate2
        yescreate2:
                mov             DWORD [ypos], 20
                ; alternatively, -MAXNOTES but I think 0 is correct
        endyescreate2:

        ; the game happens in this loop
        ; the steps are...
        ;   1. render (draw) the current board
        ;   2. get a character from the user
        ;       3. store current xpos,ypos in esi,edi
        ;       4. update xpos,ypos based on character from user
        ;       5. check what's in the buffer (board) at new xpos,ypos
        ;       6. if it's a wall, reset xpos,ypos to saved esi,edi
        ;       7. otherwise, just continue! (xpos,ypos are ok)
        game_loop:

                ; draw the game board
                call    render

                ; get an action from the user
                call    nonblocking_getchar

                cmp     al, -1
                jne     got_char

                no_char:

                        ; usleep(TICK)
                        push    TICK
                        call    usleep
                        add     esp, 4

                        ;==== NO CHAR ====

                        cmp     DWORD [createmode], 1
                        jne     nocreatenochar
                                push    0
                                call    createinput
                                add     esp, 4
                        nocreatenochar:

                        ;=================

                        jmp     end_nbgc

                got_char:
                        ; we got a char!
                        ; store the current position
                        ; we will test if the new position is legal
                        ; if not, we will restore these

                        ;==== GOTCHAR ====

                        push    eax
                        call    tolower
                        add     esp, 4

                        ; choose what to do
                        cmp             eax, EXITCHAR
                        je              game_loop_end
                        cmp             eax, GCHAR
                        je              green
                        cmp             eax, RCHAR
                        je              red
                        cmp             eax, YCHAR
                        je              yellow
                        cmp             eax, BCHAR
                        je              blue
                        cmp             eax, OCHAR
                        je              orange
                        jmp             ifnoteend ; or just do nothing

                        ; enter notes according to input
                        green:
                                push    1
                                jmp             input_execute
                        red:
                                push    2
                                jmp             input_execute
                        yellow:
                                push    3
                                jmp             input_execute
                        blue:
                                push    4
                                jmp             input_execute
                        orange:
                                push    5

                        input_execute:

                        cmp     DWORD [createmode], 1
                        jne     nocreate2
                                call    createinput
                                add     esp, 4
                                jmp     end_nbgc
                        nocreate2:
                                call    input
                                add     esp, 4

                                cmp     eax, -1
                                jne     notehit
                                        mov     DWORD [multi], 0
                                        jmp     ifnoteend
                                notehit:
                                        mov     DWORD [notes+eax*4], 0
                                        inc     DWORD [multi]
                                        mov     edx, DWORD [multi]
                                        add     DWORD [points], edx
                        ifnoteend:

                        ;=================

                end_nbgc:

                cmp     DWORD [createmode], 1
                jne     nocreate
                        dec     DWORD [ypos]
                        jmp     endcreateif
                nocreate:
                        inc     DWORD [ypos]
                        jmp     endcreateif
                endcreateif:

                jmp     game_loop
        game_loop_end:

        cmp     DWORD [createmode], 1
        jne     nocreategameend
                call    store_notes
        nocreategameend:

        ; restore old terminal functionality
        call raw_mode_off

        ;***************CODE ENDS HERE*****************************
        popa
        mov             eax, 0
        leave
        ret

; === FUNCTION ===
; parameters: key pressed
; returns: N/A
createinput:
        push    ebp
        mov     ebp, esp

                mov     ebx, DWORD [ebp+8]      ; ebp+8 = passed value
                mov     eax, HITHEIGHT
                sub     eax, 2
                sub             eax, DWORD [ypos]
                mov     BYTE [notes+eax*4], bl
;               inc     eax
;               mov     DWORD [notes+eax*4], 0

        mov     esp, ebp
        pop     ebp
        ret

; === FUNCTION ===
; parameters: key pressed
; returns: 0 if missed, location of note in array if hit
input:
        push    ebp
        mov     ebp, esp
        ;--------------------------

        ; reset debug information
        cmp     DWORD [debugmode], 1
        jne     nodebug
                call    resetdebug
        nodebug:

                mov     ebx, DWORD [ebp+8]      ; ebx = key pressed
                mov     ecx, -1                         ; ecx = return value

                mov     esi, HITHEIGHT
                add     esi, HITRANGE           ; esi = y count

                inputfory:
                mov     eax, HITHEIGHT
                sub     eax, HITRANGE
                cmp     esi, eax
                jl      inputforendy

                        mov     edi, 2                          ; edi = x count

                        inputforx:
                        cmp     edi, 10
                        jg      inputforendx

                                ; check for dot at location
                                push    ebx
                                push    ecx
                                push    edi ;push x
                                push    esi ;push y
                                call    dot_at_location
                                add     esp, 8
                                pop     ecx
                                pop     ebx

        mov DWORD [ndebug], eax

                                cmp     eax, 0
                                je      endifinput

                                ; check if dot at location matches input
                                mov     edx, esi
                                sub     edx, DWORD [ypos]

                                ;mov    eax, edi        ; I had it comparing against eax for some reason
                                ;shr    eax, 1          ; eax holds x/2, so I'm not sure why I did that
                                cmp     ebx, DWORD [notes+edx*4]
                                jne     endifinput

                                        mov ecx, edx
                                        jmp input_end

                                endifinput:

                        add     edi, 2
                        jmp     inputforx
                        inputforendx:

                dec     esi
                jmp     inputfory
                inputforendy:

                input_end:

        ;--------------------------
        mov     eax, ecx
        mov     esp, ebp
        pop     ebp
        ret

; === FUNCTION ===
; parameters: y and x
; returns: 0 if no note at location, 1 if note at location
dot_at_location:
        push    ebp
        mov     ebp, esp
        ;--------------------------

                                                ; ebp+8 = y
                                                ; ebp+12 = x
                mov     ecx, 0  ; ecx = return value

                mov     edx, DWORD [ebp+8]
                sub     edx, DWORD [ypos]
                mov     ebx, DWORD [notes+edx*4]
                add     ebx, ebx
                push    edx
                mov     eax, DWORD [ebp+8]
                mov     edx, WIDTH
                mul     edx
                add     ebx, eax

                mov     edx, DWORD [ebp+12]
                add     edx, eax

                pop     eax

                cmp     eax, 0
                jl      enddotcheck
                cmp     eax, DWORD [numnote]
                jge     enddotcheck
                cmp     edx, ebx
                jne     enddotcheck

                        mov     ecx, 1

                enddotcheck:

        ;--------------------------
        mov     eax, ecx
        mov     esp, ebp
        pop     ebp
        ret

; === FUNCTION ===
raw_mode_on:

        push    ebp
        mov             ebp, esp

        push    raw_mode_on_cmd
        call    system
        add             esp, 4

        mov             esp, ebp
        pop             ebp
        ret

; === FUNCTION ===
raw_mode_off:

        push    ebp
        mov             ebp, esp

        push    raw_mode_off_cmd
        call    system
        add             esp, 4

        mov             esp, ebp
        pop             ebp
        ret

; === FUNCTION ===
init_board:

        push    ebp
        mov             ebp, esp

        ; FILE* and loop counter
        ; ebp-4, ebp-8
        sub             esp, 8

        ; open the file
        push    mode_r
        push    board_file
        call    fopen
        add             esp, 8
        mov             DWORD [ebp-4], eax

        ; read the file data into the global buffer
        ; line-by-line so we can ignore the newline characters
        mov             DWORD [ebp-8], 0
        read_loop:
        cmp             DWORD [ebp-8], HEIGHT
        je              read_loop_end

                ; find the offset (WIDTH * counter)
                mov             eax, WIDTH
                mul             DWORD [ebp-8]
                lea             ebx, [board + eax]

                ; read the bytes into the buffer
                push    DWORD [ebp-4]
                push    WIDTH
                push    1
                push    ebx
                call    fread
                add             esp, 16

                ; slurp up the newline
                push    DWORD [ebp-4]
                call    fgetc
                add             esp, 4

        inc             DWORD [ebp-8]
        jmp             read_loop
        read_loop_end:

        ; close the open file handle
        push    DWORD [ebp-4]
        call    fclose
        add             esp, 4

        mov             esp, ebp
        pop             ebp
        ret

; === FUNCTION ===
init_notes:
        push    ebp
        mov             ebp, esp
        ;----------------

        ; FILE*, loop counter
        ; ebp-4, ebp-8
        sub             esp, 8

        ; open the file
        push    mode_r
        push    beatmap_file
        call    fopen
        add             esp, 8
        mov             DWORD [ebp-4], eax

        ; read file into notes string
        mov DWORD [numnote], 0
        mov DWORD [esp-8], 0

        xor     eax, eax
        push    DWORD [ebp-4]
        call    fgetc
        mov     ebx, eax

        read_loop2:
        cmp     ebx, -1
        je      read_loop_end2

                sub     ebx, '0'

                ;if [esp-8] % 4 == 3
                mov     eax, DWORD [ebp-8]
                cdq
                mov     esi, 4
                div     esi
                cmp     edx, 1
                jne     endifinitnotes
                        mov     eax, DWORD [numnote]
                        mov     DWORD [notes+eax*4], ebx
                        add     ebx, '0'
                        inc     DWORD [numnote]
                endifinitnotes:

                xor     eax, eax
                push    DWORD [ebp-4]
                call    fgetc
                mov     ebx, eax

        inc     DWORD [ebp-8]
        jmp             read_loop2
        read_loop_end2:

        ;reverse the beatmap
        mov     esi, notes
        mov     eax, DWORD [numnote]
        lea     edi, [notes+eax*4]

        whilenotes:
        cmp     esi, edi
        je      endwhilenotes

                lea     edi, [edi-4]
                cmp     esi, edi
                je      endwhilenotes

                mov     edx, DWORD [esi]
                mov     eax, DWORD [edi]
                mov     DWORD [esi], eax
                mov     DWORD [edi], edx

                lea     esi, [esi+4]

        jmp     whilenotes
        endwhilenotes:

        ; close the open file handle
        push    DWORD [ebp-4]
        call    fclose
        add             esp, 4

        ;----------------
        mov             esp, ebp
        pop             ebp
        ret

; === FUNCTION ===
store_notes:
        push    ebp
        mov             ebp, esp

        ; FILE*, loop counter
        ; ebp-4, ebp-8
        sub             esp, 8

        ; open the file
        push    mode_w
        push    beatmap_out_file
        call    fopen
        add             esp, 8
        mov             DWORD [ebp-4], eax

        lea     esi, [notes+1]
        mov     eax, MAXNOTES
        dec     eax
        lea     edi, [notes+eax]

        zero1:
        cmp     DWORD [esi], 0
        jne     nozero1
                lea     eax, [esi+4]
                mov     esi, eax
        jmp     zero1
        nozero1:

        zero2:
        cmp     DWORD [edi], 0
        jne     nozero2
                lea     eax, [edi-1]
                mov     edi, eax
        jmp     zero2
        nozero2:

        mov     eax, edi
        sub     eax, esi
        mov     DWORD [numnote], eax

        mov     DWORD [ebp-8], 0

        storefor:
        mov     eax, DWORD [numnote]
        cmp     DWORD [ebp-8], eax
        jg      endstorefor

                push    eax
                mov     eax, DWORD [ebp-8]
                xor     ebx, ebx
                mov     bl, BYTE [esi+eax]
                add     bl, '0'
                push    ebx
                push    crtfmt
                push    DWORD [ebp-4]
                call    fprintf
                add     esp, 12
                pop     eax

        inc     DWORD [ebp-8]
        jmp     storefor
        endstorefor:

        ; close the open file handle
        push    DWORD [ebp-4]
        call    fclose
        add             esp, 4

        mov     esp, ebp
        pop     ebp

; === FUNCTION ===
render:
        push    ebp
        mov             ebp, esp

        ; two ints, for two loop counters
        ; ebp-4, ebp-8
        sub             esp, 8

        ; clear the screen
        push    clear_screen_cmd
        call    system
        add             esp, 4

        ; print debug information
        cmp     DWORD [debugmode], 1
        jne     nodebugrender
                push    DWORD [ndebug+16]
                push    DWORD [ndebug+12]
                push    DWORD [ndebug+8]
                push    DWORD [ndebug+4]
                push    DWORD [ndebug]
                push    strfmt
                call    printf
                add     esp, 24
                push    debug
                call    printf
                add     esp, 4
        nodebugrender:

        ; print the help information
        push    help_str
        call    printf
        add             esp, 4

        ; outside loop by height
        ; i.e. for(c=0; c<height; c++)
        mov             DWORD [ebp-4], 0
        y_loop_start:
        cmp             DWORD [ebp-4], HEIGHT
        je              y_loop_end

                ; inside loop by width
                ; i.e. for(c=0; c<width; c++)
                mov             DWORD [ebp-8], 0

                x_loop_start:
                cmp             DWORD [ebp-8], WIDTH
                je              x_loop_end

                        cmp     DWORD [ebp-8], 2
                        je      clthree
                        cmp     DWORD [ebp-8], 4
                        je      clfive
                        cmp     DWORD [ebp-8], 6
                        je      clseven
                        cmp     DWORD [ebp-8], 8
                        je      clnine
                        cmp     DWORD [ebp-8], 10
                        je      cleleven
                        jmp     endcl

                        clthree:
                                push    color_green
                                call    printf
                                add     esp, 4
                                jmp     endcl
                        clfive:
                                push    color_red
                                call    printf
                                add     esp, 4
                                jmp     endcl
                        clseven:
                                push    color_yellow
                                call    printf
                                add     esp, 4
                                jmp     endcl
                        clnine:
                                push    color_blue
                                call    printf
                                add     esp, 4
                                jmp     endcl
                        cleleven:
                                push    color_orange
                                call    printf
                                add     esp, 4
                                jmp     endcl

                        endcl:

                        mov     ebx, DWORD [ebp-4] ; y counter
                        mov     edx, DWORD [ebp-8] ; x counter

                        cmp     ebx, 0
                        je      endifrender
                        inc     ebx
                        cmp     ebx, HEIGHT
                        je      endifrender
                        cmp     edx, 0
                        je      endifrender
                        inc     edx
                        cmp     edx, WIDTH
                        je      endifrender

                        mov     edx, DWORD [ypos]
;                       cmp     DWORD [createmode], 1
;                       jne     nocreaterender
;                               sub     ebx, edx
;                               add     ebx, edx
;                               jmp endcreaterender
;                               nocreaterender:
;                       endcreaterender:
                        sub     ebx, edx

                        mov     edx, DWORD [ebp-8] ; x counter

                        mov     eax, DWORD [notes+ebx*4]
                        add     eax, eax
                        cmp     eax, 0
                        je      endifrender
                        cmp     eax, edx ; notes[y] == x
                        jne     endifrender
                        cmp     ebx, 0
                        jl      endifrender
                        cmp     ebx, DWORD [numnote]
                        jge     endifrender

                                        push    color_bold
                                        call    printf
                                        add     esp, 4

                                        push    PLAYER_CHAR
                                        jmp             print_end

                        endifrender:

                        print_board:
                                ; otherwise print whatever's in the buffer
                                mov             eax, [ebp-4]
                                mov             ebx, WIDTH
                                mul             ebx
                                add             eax, [ebp-8]
                                mov             ebx, 0
                                mov             bl, BYTE [board + eax]

                                ;color rules

                                cmp     bl, '|'
                                jne     notbar
                                        push    color_dim
                                        call    printf
                                        add     esp, 4
                                notbar:

                                cmp     bl, WALL_CHAR
                                jne     notpound
                                        push    color_default
                                        call    printf
                                        add     esp, 4
                                notpound:

                                push    ebx

                        print_end:
                        call    putchar
                        add             esp, 4

                        push    color_default
                        call    printf
                        add     esp, 4

                inc             DWORD [ebp-8]
                jmp             x_loop_start
                x_loop_end:



                mov     eax, HITHEIGHT
                cmp     DWORD [ebp-4], eax
                jne     endfmtif1
                        push    DWORD [points]
                        push    ptsfmt
                        call    printf
                        add     esp, 8
                endfmtif1:

                inc     eax
                cmp     DWORD [ebp-4], eax
                jne     endfmtif2
                        push    DWORD [multi]
                        push    mulfmt
                        call    printf
                        add     esp, 8
                endfmtif2:

                ; write a carriage return (necessary when in raw mode)
                push    0x0d
                call    putchar
                add             esp, 4

                ; write a newline
                push    0x0a
                call    putchar
                add             esp, 4

        inc             DWORD [ebp-4]
        jmp             y_loop_start
        y_loop_end:

        mov             esp, ebp
        pop             ebp
        ret

; === FUNCTION ===
; returns -1 on no-data
; returns char on succes
nonblocking_getchar:
        push    ebp
        mov     ebp, esp

        ;prologue

        ; single int used to hold flags
        ; single character (aligned to 4 bytes) return
        sub     esp, 8

        ; get current stdin flags
        ; flags = fcntl(stdin, F_GETFL, 0)
        push    0
        push    F_GETFL
        push    STDIN
        call    fcntl
        add     esp, 12
        mov     DWORD [ebp-4], eax

        ; set non-blocking mode on stdin
        ; fcntl(stdin, F_SETFL, flags | O_NONBLOCK)
        or      DWORD [ebp-4], O_NONBLOCK
        push    DWORD [ebp-4]
        push    F_SETFL
        push    STDIN
        call    fcntl
        add     esp, 12

        call    getchar
        mov     DWORD [ebp-8], eax

        ; restore blocking mode
        ; fcntl(stdin, F_SETFL, flags ^ O_NONBLOCK
        xor     DWORD [ebp-4], O_NONBLOCK
        push    DWORD [ebp-4]
        push    F_SETFL
        push    STDIN
        call    fcntl
        add     esp, 12

        mov     eax, DWORD [ebp-8]

        ;epilogue

        mov     esp, ebp
        pop     ebp
        ret

; === FUNCTION ===
resetdebug:
        push    ebp
        push    ecx
        mov     ebp, esp

                xor     ecx, ecx

                resetfor:
                cmp     ecx, 5
                jge     resetforend

                        mov     DWORD [ndebug+ecx*4], ecx
                        inc     DWORD [ndebug+ecx*4]
                        neg     DWORD [ndebug+ecx*4]

                inc     ecx
                jmp     resetfor
                resetforend:

        mov     esp, ebp
        pop     ecx
        pop     ebp
        ret