METASOURCES = AUTO
noinst_LTLIBRARIES = libaudiofile.la
libaudiofile_la_SOURCES = MediaChunkFile.cpp AudioFile.cpp  LibSndFileFile.cpp  PcmFile.cpp opus_header.cpp OggOpusFile.cpp
AM_CPPFLAGS = -D_REENTRANT
libaudiofile_la_LIBADD = -logg -lopus
INCLUDES = -I@top_srcdir@ -I../../orkbasecxx -I/usr/include/opus -I/usr/include/apr-1 -I/usr/include/apr-1.0
