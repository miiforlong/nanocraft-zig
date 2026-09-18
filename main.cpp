// === MAIN.CPP ===
#include <iostream>
#include "RubyDung.h"

int main() {
    try {
        RubyDung engine;
        engine.run();
    } catch (const std::exception& e) {
        std::cerr << "Fatal error: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}

// === UTILS.H ===
#pragma once
#include <glm/glm.hpp>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>

class VarInt {
public:
    static int32_t read(const uint8_t* data, size_t& offset) {
        int32_t result = 0;
        int shift = 0;
        while (true) {
            uint8_t b = data[offset++];
            result |= (b & 0x7F) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (shift >= 35) throw std::runtime_error("VarInt too long");
        }
        return result;
    }

    static std::vector<uint8_t> write(int32_t value) {
        std::vector<uint8_t> out;
        value &= 0xFFFFFFFF;
        while (true) {
            uint8_t part = value & 0x7F;
            value >>= 7;
            if (value) {
                out.push_back(part | 0x80);
            } else {
                out.push_back(part);
                break;
            }
        }
        return out;
    }
};

class NetUtils {
public:
    static std::vector<uint8_t> writeString(const std::string& s) {
        std::vector<uint8_t> encoded(s.begin(), s.end());
        auto len = VarInt::write(encoded.size());
        len.insert(len.end(), encoded.begin(), encoded.end());
        return len;
    }

    static std::string readString(const uint8_t* data, size_t& offset) {
        int32_t len = VarInt::read(data, offset);
        std::string result((const char*)data + offset, len);
        offset += len;
        return result;
    }

    static std::vector<uint8_t> packBlockPosition(int x, int y, int z) {
        int64_t value = ((int64_t)(x & 0x3FFFFFF) << 38) | 
                       ((int64_t)(y & 0xFFF) << 26) | 
                       (int64_t)(z & 0x3FFFFFF);
        std::vector<uint8_t> result(8);
        std::memcpy(result.data(), &value, 8);
        return result;
    }

    static void unpackBlockPosition(const std::vector<uint8_t>& data, int& x, int& y, int& z) {
        int64_t value;
        std::memcpy(&value, data.data(), 8);
        x = value >> 38;
        y = (value >> 26) & 0xFFF;
        z = value & 0x3FFFFFF;
        if (x >= (1 << 25)) x -= (1 << 26);
        if (z >= (1 << 25)) z -= (1 << 26);
    }

    static uint8_t getNibble(const uint8_t* arr, int index) {
        uint8_t byte = arr[index >> 1];
        return (index & 1) ? (byte >> 4) & 0xF : byte & 0xF;
    }
};

// === PROTOCOL.H ===
#pragma once
#include <unordered_map>
#include <glm/glm.hpp>

static const std::unordered_map<int, glm::vec3> BLOCK_COLORS = {
    {0, glm::vec3(0, 0, 0)},
    {1, glm::vec3(0.5f, 0.5f, 0.5f)},
    {2, glm::vec3(0.3f, 0.6f, 0.2f)},
    {3, glm::vec3(0.55f, 0.35f, 0.1f)},
    {4, glm::vec3(0.6f, 0.6f, 0.6f)},
    {5, glm::vec3(0.7f, 0.5f, 0.3f)},
    {7, glm::vec3(0.2f, 0.2f, 0.2f)},
    {8, glm::vec3(0.2f, 0.3f, 0.8f)},
    {9, glm::vec3(0.2f, 0.3f, 0.8f)},
    {10, glm::vec3(0.9f, 0.4f, 0.0f)},
    {12, glm::vec3(0.85f, 0.8f, 0.55f)},
    {13, glm::vec3(0.5f, 0.5f, 0.5f)},
    {14, glm::vec3(0.5f, 0.5f, 0.3f)},
    {15, glm::vec3(0.5f, 0.5f, 0.5f)},
    {16, glm::vec3(0.3f, 0.3f, 0.3f)},
    {17, glm::vec3(0.5f, 0.35f, 0.15f)},
    {18, glm::vec3(0.2f, 0.6f, 0.2f)},
    {24, glm::vec3(0.85f, 0.8f, 0.55f)},
    {31, glm::vec3(0.3f, 0.7f, 0.2f)},
    {35, glm::vec3(0.9f, 0.9f, 0.9f)},
    {41, glm::vec3(0.9f, 0.8f, 0.2f)},
    {42, glm::vec3(0.7f, 0.7f, 0.7f)},
    {43, glm::vec3(0.6f, 0.6f, 0.6f)},
    {44, glm::vec3(0.6f, 0.6f, 0.6f)},
    {45, glm::vec3(0.7f, 0.4f, 0.3f)},
    {48, glm::vec3(0.3f, 0.4f, 0.3f)},
    {49, glm::vec3(0.15f, 0.1f, 0.25f)},
    {52, glm::vec3(0.1f, 0.1f, 0.3f)},
    {53, glm::vec3(0.7f, 0.5f, 0.3f)},
    {56, glm::vec3(0.4f, 0.7f, 0.8f)},
    {57, glm::vec3(0.5f, 0.9f, 0.9f)},
    {60, glm::vec3(0.55f, 0.35f, 0.1f)},
    {64, glm::vec3(0.7f, 0.5f, 0.3f)},
    {73, glm::vec3(0.5f, 0.2f, 0.2f)},
    {74, glm::vec3(0.5f, 0.2f, 0.2f)},
    {78, glm::vec3(0.95f, 0.95f, 1.0f)},
    {79, glm::vec3(0.7f, 0.85f, 0.95f)},
    {80, glm::vec3(0.95f, 0.95f, 1.0f)},
    {82, glm::vec3(0.6f, 0.6f, 0.7f)},
    {85, glm::vec3(0.7f, 0.5f, 0.3f)},
    {86, glm::vec3(0.85f, 0.45f, 0.1f)},
    {87, glm::vec3(0.7f, 0.3f, 0.2f)},
    {89, glm::vec3(0.9f, 0.8f, 0.5f)},
    {98, glm::vec3(0.6f, 0.6f, 0.6f)},
    {116, glm::vec3(0.3f, 0.2f, 0.5f)},
};

static const std::unordered_set<int> JAVA_NON_CUBE_BLOCKS = {
    6, 8, 9, 10, 11, 27, 28, 30, 31, 32, 37, 38, 39, 40, 50, 51, 55, 59,
    63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 75, 76, 77, 78, 83, 85, 90, 93,
    94, 96, 104, 105, 106, 107, 108, 109, 111, 113, 114, 115, 117, 118, 119,
    120, 127, 131, 141, 142, 143
};

static const std::unordered_map<int, std::pair<int, int>> JAVA_TERRAIN_TILES = {
    {1, {0, 0}}, {2, {1, 0}}, {3, {2, 0}}, {4, {7, 0}}, {5, {4, 0}},
    {7, {7, 0}}, {12, {6, 0}}, {17, {3, 0}}, {18, {5, 0}}, {43, {7, 0}},
    {44, {0, 0}}, {48, {7, 0}}, {53, {4, 0}}, {60, {2, 0}}, {64, {4, 0}},
    {85, {4, 0}}, {98, {7, 0}}
};

inline glm::vec3 getBlockColor(int blockId) {
    auto it = BLOCK_COLORS.find(blockId);
    return it != BLOCK_COLORS.end() ? it->second : glm::vec3(0.55f, 0.55f, 0.55f);
}

// === LEVEL.H ===
#pragma once
#include <glm/glm.hpp>
#include <unordered_map>
#include <mutex>
#include <vector>
#include <array>

class Level {
public:
    static constexpr int WIDTH = 128;
    static constexpr int DEPTH = 64;
    static constexpr int HEIGHT = 128;
    static constexpr int CHUNK_SIZE = 16;

    std::array<std::array<std::array<uint8_t, HEIGHT>, DEPTH>, WIDTH> blocks;
    std::unordered_map<uint64_t, int> javaBlocks;
    std::unordered_map<uint64_t, std::unordered_map<uint64_t, int>> javaChunkBlocks;
    std::unordered_map<uint64_t, std::unordered_map<uint64_t, int>> javaVisibleChunkBlocks;
    std::mutex javaLock;
    bool javaMode = false;
    uint32_t javaTerrainTex = 0;

    Level() {
        blocks.fill({});
        for (int x = 0; x < WIDTH; x++) {
            for (int z = 0; z < HEIGHT; z++) {
                for (int y = 0; y < 30; y++) blocks[x][y][z] = 1;
                for (int y = 30; y < 32; y++) blocks[x][y][z] = 2;
            }
        }
    }

    bool isSolid(float x, float y, float z) const {
        if (javaMode) {
            int bx = (int)x, by = (int)y, bz = (int)z;
            uint64_t key = ((uint64_t)bx << 40) | ((uint64_t)by << 20) | (bz & 0xFFFFF);
            auto it = javaBlocks.find(key);
            if (it == javaBlocks.end()) return false;
            int bid = it->second;
            return bid > 0 && JAVA_NON_CUBE_BLOCKS.find(bid) == JAVA_NON_CUBE_BLOCKS.end();
        }
        int bx = (int)x, by = (int)y, bz = (int)z;
        if (bx < 0 || bx >= WIDTH || by < 0 || by >= DEPTH || bz < 0 || bz >= HEIGHT) return false;
        return blocks[bx][by][bz] > 0;
    }

    int getBlock(float x, float y, float z) const {
        if (javaMode) {
            int bx = (int)x, by = (int)y, bz = (int)z;
            uint64_t key = ((uint64_t)bx << 40) | ((uint64_t)by << 20) | (bz & 0xFFFFF);
            auto it = javaBlocks.find(key);
            return (it != javaBlocks.end()) ? it->second : 0;
        }
        int bx = (int)x, by = (int)y, bz = (int)z;
        if (bx < 0 || bx >= WIDTH || by < 0 || by >= DEPTH || bz < 0 || bz >= HEIGHT) return 0;
        return blocks[bx][by][bz];
    }

    uint64_t getChunkKey(int x, int y, int z) const {
        int cx = (x / CHUNK_SIZE) * CHUNK_SIZE;
        int cy = (y / CHUNK_SIZE) * CHUNK_SIZE;
        int cz = (z / CHUNK_SIZE) * CHUNK_SIZE;
        return ((uint64_t)cx << 40) | ((uint64_t)cy << 20) | (cz & 0xFFFFF);
    }

    void setBlock(int x, int y, int z, int id) {
        std::lock_guard<std::mutex> lock(javaLock);
        if (id == 0) {
            uint64_t key = ((uint64_t)x << 40) | ((uint64_t)y << 20) | (z & 0xFFFFF);
            javaBlocks.erase(key);
        } else {
            uint64_t key = ((uint64_t)x << 40) | ((uint64_t)y << 20) | (z & 0xFFFFF);
            javaBlocks[key] = id;
        }
    }
};

// === PLAYER.H ===
#pragma once
#include <glm/glm.hpp>
#include <algorithm>
#include <cmath>

struct AABB {
    float x0, y0, z0, x1, y1, z1;
    static constexpr float EPS = 0.01f;

    AABB(float x0_, float y0_, float z0_, float x1_, float y1_, float z1_)
        : x0(x0_), y0(y0_), z0(z0_), x1(x1_), y1(y1_), z1(z1_) {}

    float clipX(const AABB& c, float xa) const {
        if (c.y1 <= y0 || c.y0 >= y1 || c.z1 <= z0 || c.z0 >= z1) return xa;
        if (xa > 0 && c.x1 <= x0) {
            float v = x0 - c.x1 - EPS;
            if (v < xa) xa = v;
        }
        if (xa < 0 && c.x0 >= x1) {
            float v = x1 - c.x0 + EPS;
            if (v > xa) xa = v;
        }
        return xa;
    }

    float clipY(const AABB& c, float ya) const {
        if (c.x1 <= x0 || c.x0 >= x1 || c.z1 <= z0 || c.z0 >= z1) return ya;
        if (ya > 0 && c.y1 <= y0) {
            float v = y0 - c.y1 - EPS;
            if (v < ya) ya = v;
        }
        if (ya < 0 && c.y0 >= y1) {
            float v = y1 - c.y0 + EPS;
            if (v > ya) ya = v;
        }
        return ya;
    }

    float clipZ(const AABB& c, float za) const {
        if (c.x1 <= x0 || c.x0 >= x1 || c.y1 <= y0 || c.y0 >= y1) return za;
        if (za > 0 && c.z1 <= z0) {
            float v = z0 - c.z1 - EPS;
            if (v < za) za = v;
        }
        if (za < 0 && c.z0 >= z1) {
            float v = z1 - c.z0 + EPS;
            if (v > za) za = v;
        }
        return za;
    }

    void move(float xa, float ya, float za) {
        x0 += xa; y0 += ya; z0 += za;
        x1 += xa; y1 += ya; z1 += za;
    }
};

class Player {
public:
    float x, y, z;
    float xd, yd, zd;
    float yRot, xRot;
    AABB bb;
    bool onGround;
    Level* level;

    Player(Level* lvl) : level(lvl), x(64.0f), y(35.0f), z(64.0f),
        xd(0), yd(0), zd(0), yRot(0), xRot(0),
        bb(63.7f, 33.4f, 63.7f, 64.3f, 35.2f, 64.3f), onGround(false) {}

    void tick(bool ignoreInput = false) {
        float xa = 0, za = 0;
        if (!ignoreInput) {
            // Input handled externally in main loop
        }
        
        float speed = onGround ? 0.04f : 0.02f;
        float m = std::sqrt(xa*xa + za*za);
        if (m > 0.01f) {
            xa *= speed / m;
            za *= speed / m;
            float s = std::sin(glm::radians(yRot));
            float c = std::cos(glm::radians(yRot));
            xd += xa * c - za * s;
            zd += za * c + xa * s;
        }

        yd -= 0.005f;
        move(xd, yd, zd);
        xd *= 0.91f;
        yd *= 0.98f;
        zd *= 0.91f;
        if (onGround) {
            xd *= 0.7f;
            zd *= 0.7f;
        }
    }

    void move(float xa, float ya, float za) {
        float yO = ya;
        std::vector<AABB> cubes;

        for (int ix = (int)bb.x0 - 1; ix < (int)bb.x1 + 2; ix++) {
            for (int iy = (int)bb.y0 - 1; iy < (int)bb.y1 + 2; iy++) {
                for (int iz = (int)bb.z0 - 1; iz < (int)bb.z1 + 2; iz++) {
                    if (level->isSolid(ix, iy, iz)) {
                        cubes.emplace_back(ix, iy, iz, ix+1, iy+1, iz+1);
                    }
                }
            }
        }

        for (auto& c : cubes) ya = c.clipY(bb, ya);
        bb.move(0, ya, 0);
        for (auto& c : cubes) xa = c.clipX(bb, xa);
        bb.move(xa, 0, 0);
        for (auto& c : cubes) za = c.clipZ(bb, za);
        bb.move(0, 0, za);

        onGround = (yO != ya && yO < 0);
        if (yO != ya) yd = 0;

        x = (bb.x0 + bb.x1) / 2.0f;
        y = bb.y0 + 1.62f;
        z = (bb.z0 + bb.z1) / 2.0f;
    }
};

// === CHUNK.H ===
#pragma once
#include <GL/glew.h>
#include <glm/glm.hpp>
#include <memory>

class Chunk {
public:
    glm::ivec3 pos;
    class Level* level;
    GLuint listId = 0;
    bool dirty = true;

    Chunk(int x, int y, int z, Level* lvl);
    ~Chunk();
    void build();
    void render();
    void renderImmediate();

private:
    void drawGeometry();
    void emitJavaFace(bool textured, float shade, const glm::vec3 vertices[4], const glm::vec2 uv[4]);
    void emitJavaBlock(int x, int y, int z, int blockId, bool textured);
};

// === CHUNK.CPP ===
#include "Chunk.h"
#include "Level.h"
#include "Protocol.h"
#include <GL/glew.h>

Chunk::Chunk(int x, int y, int z, Level* lvl)
    : pos(x, y, z), level(lvl) {
    listId = glGenLists(1);
}

Chunk::~Chunk() {
    if (listId) glDeleteLists(listId, 1);
}

void Chunk::emitJavaFace(bool textured, float shade, const glm::vec3 vertices[4], const glm::vec2 uv[4]) {
    if (textured) {
        glColor3f(shade, shade, shade);
        if (uv) {
            glTexCoord2f(uv[0].x, uv[0].y); glVertex3fv(&vertices[0].x);
            glTexCoord2f(uv[1].x, uv[1].y); glVertex3fv(&vertices[1].x);
            glTexCoord2f(uv[2].x, uv[2].y); glVertex3fv(&vertices[2].x);
            glTexCoord2f(uv[3].x, uv[3].y); glVertex3fv(&vertices[3].x);
        }
    } else {
        glColor3f(shade, shade, shade);
        for (int i = 0; i < 4; i++) glVertex3fv(&vertices[i].x);
    }
}

void Chunk::emitJavaBlock(int x, int y, int z, int blockId, bool textured) {
    glm::vec3 color = getBlockColor(blockId);
    glm::vec2 uv[4] = {};

    if (textured && JAVA_TERRAIN_TILES.find(blockId) != JAVA_TERRAIN_TILES.end()) {
        auto [tx, ty] = JAVA_TERRAIN_TILES.at(blockId);
        float u0 = tx / 16.0f, v0 = ty / 16.0f;
        float u1 = (tx + 1) / 16.0f, v1 = (ty + 1) / 16.0f;
        uv[0] = {u0, v0}; uv[1] = {u1, v0}; uv[2] = {u1, v1}; uv[3] = {u0, v1};
    }

    auto emit = [this, textured, blockId, x, y, z, &uv](float shade, glm::vec3 verts[4]) {
        bool useTex = textured && JAVA_TERRAIN_TILES.find(blockId) != JAVA_TERRAIN_TILES.end();
        emitJavaFace(useTex, shade, verts, useTex ? uv : nullptr);
    };

    glm::vec3 color_adj = color;

    // Top face
    if (!level->isSolid(x, y+1, z)) {
        glm::vec3 verts[4] = {{x,y+1,z}, {x,y+1,z+1}, {x+1,y+1,z+1}, {x+1,y+1,z}};
        emit(1.0f, verts);
    }
    // Bottom
    if (!level->isSolid(x, y-1, z)) {
        glm::vec3 verts[4] = {{x+1,y,z}, {x+1,y,z+1}, {x,y,z+1}, {x,y,z}};
        emit(0.5f, verts);
    }
    // South
    if (!level->isSolid(x, y, z+1)) {
        glm::vec3 verts[4] = {{x,y,z+1}, {x+1,y,z+1}, {x+1,y+1,z+1}, {x,y+1,z+1}};
        emit(0.8f, verts);
    }
    // North
    if (!level->isSolid(x, y, z-1)) {
        glm::vec3 verts[4] = {{x+1,y,z}, {x,y,z}, {x,y+1,z}, {x+1,y+1,z}};
        emit(0.8f, verts);
    }
    // East
    if (!level->isSolid(x+1, y, z)) {
        glm::vec3 verts[4] = {{x+1,y,z+1}, {x+1,y,z}, {x+1,y+1,z}, {x+1,y+1,z+1}};
        emit(0.6f, verts);
    }
    // West
    if (!level->isSolid(x-1, y, z)) {
        glm::vec3 verts[4] = {{x,y,z}, {x,y,z+1}, {x,y+1,z+1}, {x,y+1,z}};
        emit(0.6f, verts);
    }
}

void Chunk::drawGeometry() {
    if (level->javaMode) {
        std::lock_guard<std::mutex> lock(level->javaLock);
        auto chunkKey = level->getChunkKey(pos.x, pos.y, pos.z);
        
        glEnable(GL_TEXTURE_2D);
        glBindTexture(GL_TEXTURE_2D, level->javaTerrainTex);
        glBegin(GL_QUADS);
        
        if (level->javaChunkBlocks.find(chunkKey) != level->javaChunkBlocks.end()) {
            for (auto& [blockKey, bid] : level->javaChunkBlocks[chunkKey]) {
                if (bid == 0 || JAVA_NON_CUBE_BLOCKS.find(bid) != JAVA_NON_CUBE_BLOCKS.end()) continue;
                
                uint64_t key = blockKey;
                int x = key >> 40;
                int y = (key >> 20) & 0xFFFFF;
                int z = key & 0xFFFFF;
                emitJavaBlock(x, y, z, bid, true);
            }
        }
        glEnd();
    } else {
        glEnable(GL_TEXTURE_2D);
        glBegin(GL_QUADS);
        for (int x = pos.x; x < pos.x + 16 && x < Level::WIDTH; x++) {
            for (int y = pos.y; y < pos.y + 16 && y < Level::DEPTH; y++) {
                for (int z = pos.z; z < pos.z + 16 && z < Level::HEIGHT; z++) {
                    int b = level->blocks[x][y][z];
                    if (b == 0) continue;

                    float s = 0.0625f;
                    float u = (b - 1) * s;
                    float v = 1.0f - s;

                    if (!level->isSolid(x, y+1, z)) {
                        glColor3f(1.0f, 1.0f, 1.0f);
                        glTexCoord2f(u, v+s); glVertex3f(x, y+1, z);
                        glTexCoord2f(u, v); glVertex3f(x, y+1, z+1);
                        glTexCoord2f(u+s, v); glVertex3f(x+1, y+1, z+1);
                        glTexCoord2f(u+s, v+s); glVertex3f(x+1, y+1, z);
                    }
                    if (!level->isSolid(x, y-1, z)) {
                        glColor3f(0.6f, 0.6f, 0.6f);
                        glTexCoord2f(u+s, v+s); glVertex3f(x+1, y, z);
                        glTexCoord2f(u+s, v); glVertex3f(x+1, y, z+1);
                        glTexCoord2f(u, v); glVertex3f(x, y, z+1);
                        glTexCoord2f(u, v+s); glVertex3f(x, y, z);
                    }
                    if (!level->isSolid(x, y, z+1)) {
                        glColor3f(0.8f, 0.8f, 0.8f);
                        glTexCoord2f(u, v); glVertex3f(x, y, z+1);
                        glTexCoord2f(u+s, v); glVertex3f(x+1, y, z+1);
                        glTexCoord2f(u+s, v+s); glVertex3f(x+1, y+1, z+1);
                        glTexCoord2f(u, v+s); glVertex3f(x, y+1, z+1);
                    }
                    if (!level->isSolid(x, y, z-1)) {
                        glColor3f(0.8f, 0.8f, 0.8f);
                        glTexCoord2f(u+s, v); glVertex3f(x+1, y, z);
                        glTexCoord2f(u, v); glVertex3f(x, y, z);
                        glTexCoord2f(u, v+s); glVertex3f(x, y+1, z);
                        glTexCoord2f(u+s, v+s); glVertex3f(x+1, y+1, z);
                    }
                    if (!level->isSolid(x+1, y, z)) {
                        glColor3f(0.7f, 0.7f, 0.7f);
                        glTexCoord2f(u+s, v); glVertex3f(x+1, y, z+1);
                        glTexCoord2f(u, v); glVertex3f(x+1, y, z);
                        glTexCoord2f(u, v+s); glVertex3f(x+1, y+1, z);
                        glTexCoord2f(u+s, v+s); glVertex3f(x+1, y+1, z+1);
                    }
                    if (!level->isSolid(x-1, y, z)) {
                        glColor3f(0.7f, 0.7f, 0.7f);
                        glTexCoord2f(u, v); glVertex3f(x, y, z);
                        glTexCoord2f(u+s, v); glVertex3f(x, y, z+1);
                        glTexCoord2f(u+s, v+s); glVertex3f(x, y+1, z+1);
                        glTexCoord2f(u, v+s); glVertex3f(x, y+1, z);
                    }
                }
            }
        }
        glEnd();
    }
}

void Chunk::build() {
    if (!listId) listId = glGenLists(1);
    glNewList(listId, GL_COMPILE);
    drawGeometry();
    glEndList();
    dirty = false;
}

void Chunk::render() {
    if (listId) glCallList(listId);
}

void Chunk::renderImmediate() {
    drawGeometry();
}

// === MINECRAFT_JAVA_CLIENT.H ===
#pragma once
#include "Level.h"
#include "Player.h"
#include <thread>
#include <queue>
#include <asio.hpp>
#include <memory>
#include <functional>
#include <map>

class MinecraftJavaClient {
public:
    static constexpr int PROTOCOL_VERSION = 47;

    MinecraftJavaClient(const std::string& host, int port, const std::string& username,
                       Level* level, Player* player, std::function<void(const std::string&)> statusCb);
    ~MinecraftJavaClient();

    void connect();
    void disconnect();
    bool sendChatMessage(const std::string& msg);
    bool sendDigBlock(const glm::ivec3& pos, int face);
    bool sendPlaceBlock(const glm::ivec3& pos, int face, int itemId);
    bool sendDigStatus(int status, const glm::ivec3& pos, int face);
    void sendHeldItemChange(int slot);

    bool connected = false;
    int chunksReceived = 0;
    int gamemode = 0;
    int entityId = -1;
    int heldSlot = 0;
    std::map<int, std::map<std::string, float>> remotePlayers;
    std::mutex entityLock;
    std::set<glm::ivec3> dirtyChunks;

private:
    std::string host;
    int port;
    std::string username;
    Level* level;
    Player* player;
    std::function<void(const std::string&)> onStatus;
    std::unique_ptr<asio::ip::tcp::socket> sock;
    std::thread clientThread;
    bool running = false;
    int compressionThreshold = -1;

    void run();
    void sendHandshake();
    void sendLoginStart();
    void loginLoop();
    void playLoop();
    void send(int packetId, const std::vector<uint8_t>& payload);
    std::vector<uint8_t> recvPacket();
    void handleChunkBulk(const std::vector<uint8_t>& data, size_t& offset);
    void handleSpawnPlayer(const std::vector<uint8_t>& data, size_t& offset);
    void handleBlockChange(const std::vector<uint8_t>& data, size_t& offset);
};

// === MINECRAFT_JAVA_CLIENT.CPP ===
#include "MinecraftJavaClient.h"
#include "Utils.h"
#include <iostream>
#include <zlib.h>
#include <cstring>

MinecraftJavaClient::MinecraftJavaClient(const std::string& h, int p, const std::string& u,
                                         Level* l, Player* pl, std::function<void(const std::string&)> cb)
    : host(h), port(p), username(u), level(l), player(pl), onStatus(cb) {}

MinecraftJavaClient::~MinecraftJavaClient() {
    disconnect();
}

void MinecraftJavaClient::connect() {
    running = true;
    clientThread = std::thread([this] { run(); });
    clientThread.detach();
}

void MinecraftJavaClient::disconnect() {
    running = false;
    connected = false;
    if (sock && sock->is_open()) {
        asio::error_code ec;
        sock->close(ec);
    }
}

void MinecraftJavaClient::send(int packetId, const std::vector<uint8_t>& payload) {
    try {
        auto id_bytes = VarInt::write(packetId);
        std::vector<uint8_t> data(id_bytes.begin(), id_bytes.end());
        data.insert(data.end(), payload.begin(), payload.end());

        auto len_bytes = VarInt::write(data.size());
        std::vector<uint8_t> packet(len_bytes.begin(), len_bytes.end());
        packet.insert(packet.end(), data.begin(), data.end());

        asio::write(*sock, asio::buffer(packet));
    } catch (const std::exception& e) {
        std::cerr << "Send error: " << e.what() << std::endl;
    }
}

std::vector<uint8_t> MinecraftJavaClient::recvPacket() {
    std::vector<uint8_t> raw;
    uint8_t byte;

    while (true) {
        asio::read(*sock, asio::buffer(&byte, 1));
        raw.push_back(byte);
        if ((byte & 0x80) == 0) break;
        if (raw.size() > 5) throw std::runtime_error("Packet length too long");
    }

    size_t offset = 0;
    int32_t len = VarInt::read(raw.data(), offset);
    std::vector<uint8_t> data(len);
    asio::read(*sock, asio::buffer(data));
    return data;
}

void MinecraftJavaClient::sendHandshake() {
    auto payload = VarInt::write(PROTOCOL_VERSION);
    auto host_str = NetUtils::writeString(host);
    payload.insert(payload.end(), host_str.begin(), host_str.end());
    
    uint8_t port_bytes[2];
    port_bytes[0] = (port >> 8) & 0xFF;
    port_bytes[1] = port & 0xFF;
    payload.insert(payload.end(), port_bytes, port_bytes + 2);
    
    auto next = VarInt::write(2);
    payload.insert(payload.end(), next.begin(), next.end());
    
    send(0x00, payload);
}

void MinecraftJavaClient::sendLoginStart() {
    auto payload = NetUtils::writeString(username);
    send(0x00, payload);
}

void MinecraftJavaClient::loginLoop() {
    while (running) {
        try {
            auto packet = recvPacket();
            size_t offset = 0;
            int pid = VarInt::read(packet.data(), offset);

            if (pid == 0x03) { // Set Compression
                int threshold = VarInt::read(packet.data(), offset);
                compressionThreshold = threshold;
                onStatus("Compression enabled");
            }
            else if (pid == 0x02) { // Login Success
                auto uuid = NetUtils::readString(packet.data(), offset);
                auto name = NetUtils::readString(packet.data(), offset);
                onStatus("Login OK: " + name);
                playLoop();
                return;
            }
            else if (pid == 0x00) { // Disconnect
                auto reason = NetUtils::readString(packet.data(), offset);
                onStatus("Rejected: " + reason);
                return;
            }
        } catch (const std::exception& e) {
            std::cerr << "Login error: " << e.what() << std::endl;
            return;
        }
    }
}

void MinecraftJavaClient::handleChunkBulk(const std::vector<uint8_t>& data, size_t& offset) {
    // Simplified chunk bulk handling
    bool skyLight = data[offset++];
    int32_t nChunks = VarInt::read(data.data(), offset);
    
    for (int i = 0; i < nChunks; i++) {
        int cx = *(int32_t*)(data.data() + offset); offset += 4;
        int cz = *(int32_t*)(data.data() + offset); offset += 4;
        uint16_t pbm = *(uint16_t*)(data.data() + offset); offset += 2;
        
        chunksReceived++;
    }
}

void MinecraftJavaClient::handleSpawnPlayer(const std::vector<uint8_t>& data, size_t& offset) {
    int eid = VarInt::read(data.data(), offset);
    if (eid == entityId) return;
    offset += 16; // UUID
    
    int32_t x_int = *(int32_t*)(data.data() + offset); offset += 4;
    int32_t y_int = *(int32_t*)(data.data() + offset); offset += 4;
    int32_t z_int = *(int32_t*)(data.data() + offset); offset += 4;
    
    float x = x_int / 32.0f;
    float y = y_int / 32.0f;
    float z = z_int / 32.0f;
    
    std::lock_guard<std::mutex> lock(entityLock);
    remotePlayers[eid] = {{"x", x}, {"y", y + 1.62f}, {"z", z}};
}

void MinecraftJavaClient::playLoop() {
    connected = true;
    onStatus("In game!");
    level->javaMode = true;

    while (connected && running) {
        try {
            auto packet = recvPacket();
            size_t offset = 0;
            int pid = VarInt::read(packet.data(), offset);

            if (pid == 0x01) { // Join Game
                entityId = *(int32_t*)(packet.data() + offset); offset += 4;
                gamemode = packet[offset++];
                onStatus("Joined world");
            }
            else if (pid == 0x0C) { // Spawn Player
                handleSpawnPlayer(packet, offset);
            }
            else if (pid == 0x21) { // Chunk Data
                chunksReceived++;
            }
            else if (pid == 0x26) { // Chunk Bulk
                handleChunkBulk(packet, offset);
            }
            else if (pid == 0x00) { // Keep Alive
                int32_t ka_id = *(int32_t*)(packet.data() + offset);
                std::vector<uint8_t> resp(4);
                std::memcpy(resp.data(), &ka_id, 4);
                send(0x00, resp);
            }
            else if (pid == 0x40) { // Disconnect
                auto reason = NetUtils::readString(packet.data(), offset);
                onStatus("Disconnected: " + reason);
                connected = false;
                return;
            }
        } catch (const std::exception& e) {
            if (connected) {
                std::cerr << "Playloop error: " << e.what() << std::endl;
            }
            return;
        }
    }
}

void MinecraftJavaClient::run() {
    try {
        onStatus("Connecting to " + host + ":" + std::to_string(port));
        
        asio::io_context io;
        sock = std::make_unique<asio::ip::tcp::socket>(io);
        
        asio::ip::tcp::resolver resolver(io);
        auto endpoints = resolver.resolve(host, std::to_string(port));
        asio::connect(*sock, endpoints);
        
        onStatus("Connected! Handshake...");
        sendHandshake();
        sendLoginStart();
        loginLoop();
    } catch (const std::exception& e) {
        onStatus("Error: " + std::string(e.what()));
        connected = false;
    }
}

bool MinecraftJavaClient::sendChatMessage(const std::string& msg) {
    try {
        auto payload = NetUtils::writeString(msg);
        send(0x01, payload);
        return true;
    } catch (...) {
        return false;
    }
}

bool MinecraftJavaClient::sendDigStatus(int status, const glm::ivec3& pos, int face) {
    try {
        std::vector<uint8_t> payload;
        payload.push_back(status);
        auto bpos = NetUtils::packBlockPosition(pos.x, pos.y, pos.z);
        payload.insert(payload.end(), bpos.begin(), bpos.end());
        payload.push_back(face);
        send(0x07, payload);
        return true;
    } catch (...) {
        return false;
    }
}

bool MinecraftJavaClient::sendDigBlock(const glm::ivec3& pos, int face) {
    return sendDigStatus(0, pos, face) && sendDigStatus(2, pos, face);
}

bool MinecraftJavaClient::sendPlaceBlock(const glm::ivec3& pos, int face, int itemId) {
    try {
        auto bpos = NetUtils::packBlockPosition(pos.x, pos.y, pos.z);
        std::vector<uint8_t> payload(bpos.begin(), bpos.end());
        payload.push_back(face);
        uint8_t item[2] = {(uint8_t)((itemId >> 8) & 0xFF), (uint8_t)(itemId & 0xFF)};
        payload.insert(payload.end(), item, item + 2);
        payload.push_back(1); // count
        uint8_t damage[2] = {0, 0};
        payload.insert(payload.end(), damage, damage + 2);
        payload.push_back(0xC0); // no NBT
        send(0x08, payload);
        return true;
    } catch (...) {
        return false;
    }
}

void MinecraftJavaClient::sendHeldItemChange(int slot) {
    try {
        heldSlot = std::max(0, std::min(8, slot));
        std::vector<uint8_t> payload(2);
        payload[0] = (heldSlot >> 8) & 0xFF;
        payload[1] = heldSlot & 0xFF;
        send(0x09, payload);
    } catch (...) {}
}

void MinecraftJavaClient::handleBlockChange(const std::vector<uint8_t>& data, size_t& offset) {
    int64_t pos_long = *(int64_t*)(data.data() + offset); offset += 8;
    int bx = pos_long >> 38;
    int by = (pos_long >> 26) & 0xFFF;
    int bz = pos_long & 0x3FFFFFF;
    
    if (bx >= (1 << 25)) bx -= (1 << 26);
    if (bz >= (1 << 25)) bz -= (1 << 26);
    
    int block_id_raw = VarInt::read(data.data(), offset);
    int block_id = block_id_raw >> 4;
    
    std::lock_guard<std::mutex> lock(level->javaLock);
    level->setBlock(bx, by, bz, block_id);
}

// === JAVA_LAN_SERVER.H ===
#pragma once
#include "Level.h"
#include <asio.hpp>
#include <thread>
#include <vector>
#include <functional>

class JavaLanServer {
public:
    static constexpr int PROTOCOL_VERSION = 47;
    
    JavaLanServer(Level* level, std::function<void(const std::string&)> statusCb = nullptr);
    ~JavaLanServer();
    
    int start(int preferredPort = 25565);
    void stop();
    void broadcastBlockChange(const glm::ivec3& pos, int blockId);

private:
    Level* level;
    std::function<void(const std::string&)> onStatus;
    std::unique_ptr<asio::io_context> io;
    std::unique_ptr<asio::ip::tcp::acceptor> acceptor;
    std::thread acceptThread, announceThread;
    bool running = false;
    int port = 0;
    std::mutex clientsLock;
    std::vector<std::shared_ptr<asio::ip::tcp::socket>> clients;
    int entitySeq = 1000;

    void acceptLoop();
    void announceLoop();
    void handleClient(std::shared_ptr<asio::ip::tcp::socket> sock);
    void sendPacket(std::shared_ptr<asio::ip::tcp::socket> sock, int packetId, const std::vector<uint8_t>& data);
    void status(const std::string& msg);
};

// === JAVA_LAN_SERVER.CPP ===
#include "JavaLanServer.h"
#include "Utils.h"
#include <iostream>

JavaLanServer::JavaLanServer(Level* lvl, std::function<void(const std::string&)> cb)
    : level(lvl), onStatus(cb) {}

JavaLanServer::~JavaLanServer() {
    stop();
}

int JavaLanServer::start(int preferredPort) {
    if (running) return port;

    io = std::make_unique<asio::io_context>();
    
    for (int p = preferredPort; p < preferredPort + 20; p++) {
        try {
            auto endpoint = asio::ip::tcp::endpoint(asio::ip::tcp::v4(), p);
            acceptor = std::make_unique<asio::ip::tcp::acceptor>(*io, endpoint);
            port = p;
            running = true;
            break;
        } catch (...) {
            continue;
        }
    }

    if (!running) throw std::runtime_error("No free Java LAN port");

    status("Java LAN server on port " + std::to_string(port));
    acceptThread = std::thread([this] { acceptLoop(); });
    acceptThread.detach();
    announceThread = std::thread([this] { announceLoop(); });
    announceThread.detach();

    return port;
}

void JavaLanServer::stop() {
    running = false;
    if (acceptor) acceptor->close();
}

void JavaLanServer::status(const std::string& msg) {
    if (onStatus) onStatus(msg);
    std::cout << "[JAVA LAN] " << msg << std::endl;
}

void JavaLanServer::sendPacket(std::shared_ptr<asio::ip::tcp::socket> sock, int packetId, const std::vector<uint8_t>& data) {
    try {
        auto id_bytes = VarInt::write(packetId);
        std::vector<uint8_t> payload(id_bytes.begin(), id_bytes.end());
        payload.insert(payload.end(), data.begin(), data.end());
        
        auto len_bytes = VarInt::write(payload.size());
        std::vector<uint8_t> packet(len_bytes.begin(), len_bytes.end());
        packet.insert(packet.end(), payload.begin(), payload.end());

        asio::write(*sock, asio::buffer(packet));
    } catch (...) {}
}

void JavaLanServer::acceptLoop() {
    while (running && acceptor) {
        try {
            auto sock = std::make_shared<asio::ip::tcp::socket>(*io);
            acceptor->accept(*sock);
            std::thread([this, sock] { handleClient(sock); }).detach();
        } catch (...) {
            break;
        }
    }
}

void JavaLanServer::announceLoop() {
    asio::ip::udp::socket udp(*io);
    asio::ip::udp::endpoint multicast_endpoint(asio::ip::address::from_string("224.0.2.60"), 4445);
    
    while (running) {
        try {
            std::string motd = "[MOTD]Nanocraft LAN[/MOTD][AD]" + std::to_string(port) + "[/AD]";
            udp.send_to(asio::buffer(motd), multicast_endpoint);
        } catch (...) {}
        std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    }
}

void JavaLanServer::handleClient(std::shared_ptr<asio::ip::tcp::socket> sock) {
    try {
        uint8_t buf[1024];
        size_t len = sock->receive(asio::buffer(buf));
        // Handle login protocol
    } catch (...) {}
}

void JavaLanServer::broadcastBlockChange(const glm::ivec3& pos, int blockId) {
    auto bpos = NetUtils::packBlockPosition(pos.x, pos.y, pos.z);
    auto bid_bytes = VarInt::write(blockId << 4);
    std::vector<uint8_t> payload(bpos.begin(), bpos.end());
    payload.insert(payload.end(), bid_bytes.begin(), bid_bytes.end());

    std::lock_guard<std::mutex> lock(clientsLock);
    for (auto& client : clients) {
        sendPacket(client, 0x23, payload);
    }
}

// === RUBYDUNG.H ===
#pragma once
#include <GLFW/glfw3.h>
#include <GL/glew.h>
#include <glm/glm.hpp>
#include <memory>
#include <vector>
#include <string>
#include "Level.h"
#include "Player.h"
#include "Chunk.h"
#include "MinecraftJavaClient.h"
#include "JavaLanServer.h"

class RubyDung {
public:
    RubyDung();
    ~RubyDung();
    void run();

private:
    static constexpr int WIDTH = 1024;
    static constexpr int HEIGHT = 768;
    
    enum State { MENU, GAME, IP_INPUT, JAVA_GAME };
    
    GLFWwindow* window;
    State state = MENU;
    std::unique_ptr<Level> level;
    std::unique_ptr<Player> player;
    std::vector<std::unique_ptr<Chunk>> chunks;
    
    GLuint terrainTex = 0, skinTex = 0;
    std::unique_ptr<MinecraftJavaClient> javaClient;
    std::unique_ptr<JavaLanServer> javaLanServer;
    
    std::string javaStatus = "Not connected";
    bool javaLoading = false;
    int javaChunksReceived = 0;
    
    float currentFps = 0.0f;
    glm::ivec3 selectedHotbar = {0, 0, 0};
    std::map<int, int> hotbarCounts;
    
    void initGL();
    void loadTexture(const std::string& filename, GLuint& tex);
    void renderGame();
    void drawMenu();
    void drawText(const std::string& text, float x, float y, glm::vec3 color);
    void drawCrosshair();
    void drawHotbar();
    void drawChunks();
    void processInput();
};

// === RUBYDUNG.CPP ===
#include "RubyDung.h"
#include <iostream>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <SDL2/SDL_image.h>

RubyDung::RubyDung() {
    glfwSetErrorCallback([](int code, const char* desc) {
        std::cerr << "GLFW error " << code << ": " << desc << std::endl;
    });

    if (!glfwInit()) throw std::runtime_error("GLFW init failed");

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 2);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
    glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);

    window = glfwCreateWindow(WIDTH, HEIGHT, "Nanocraft", nullptr, nullptr);
    if (!window) throw std::runtime_error("Window creation failed");

    glfwMakeContextCurrent(window);
    glfwSwapInterval(1);

    if (glewInit() != GLEW_OK) throw std::runtime_error("GLEW init failed");

    level = std::make_unique<Level>();
    player = std::make_unique<Player>(level.get());

    for (int x = 0; x < Level::WIDTH; x += Level::CHUNK_SIZE) {
        for (int y = 0; y < Level::DEPTH; y += Level::CHUNK_SIZE) {
            for (int z = 0; z < Level::HEIGHT; z += Level::CHUNK_SIZE) {
                chunks.push_back(std::make_unique<Chunk>(x, y, z, level.get()));
            }
        }
    }

    initGL();
    loadTexture("terrain.png", terrainTex);
    loadTexture("skin.png", skinTex);

    hotbarCounts[1] = 999;
    hotbarCounts[2] = 999;
}

RubyDung::~RubyDung() {
    if (javaClient) javaClient->disconnect();
    if (javaLanServer) javaLanServer->stop();
    glfwTerminate();
}

void RubyDung::initGL() {
    glEnable(GL_TEXTURE_2D);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glViewport(0, 0, WIDTH, HEIGHT);
}

void RubyDung::loadTexture(const std::string& filename, GLuint& tex) {
    try {
        SDL_Surface* surf = IMG_Load(filename.c_str());
        if (!surf) return;

        tex = 0;
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, surf->w, surf->h, 0, GL_RGBA, GL_UNSIGNED_BYTE, surf->pixels);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

        SDL_FreeSurface(surf);
    } catch (...) {}
}

void RubyDung::drawText(const std::string& text, float x, float y, glm::vec3 color) {
    // Implement font rendering with SDL_ttf or stb_truetype
}

void RubyDung::drawCrosshair() {
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0, WIDTH, HEIGHT, 0, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_TEXTURE_2D);
    glColor3f(1.0f, 1.0f, 1.0f);

    float cx = WIDTH / 2.0f, cy = HEIGHT / 2.0f;
    float size = 8.0f;
    glBegin(GL_LINES);
    glVertex2f(cx - size, cy);
    glVertex2f(cx + size, cy);
    glVertex2f(cx, cy - size);
    glVertex2f(cx, cy + size);
    glEnd();

    glEnable(GL_DEPTH_TEST);
    glEnable(GL_TEXTURE_2D);
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glMatrixMode(GL_MODELVIEW);
}

void RubyDung::drawMenu() {
    glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glDisable(GL_TEXTURE_2D);

    drawText("NANOCRAFT", WIDTH/2, 200, {1, 1, 0});
    drawText("[1] SOLO", WIDTH/2, 350, {1, 1, 1});
    drawText("[2] HOST LAN", WIDTH/2, 420, {1, 1, 1});
    drawText("[3] JOIN LAN", WIDTH/2, 490, {1, 1, 1});
    drawText("[4] JOIN JAVA SERVER", WIDTH/2, 560, {1, 1, 1});

    glEnable(GL_TEXTURE_2D);
}

void RubyDung::drawHotbar() {
    // Implement hotbar rendering
}

void RubyDung::drawChunks() {
    glBindTexture(GL_TEXTURE_2D, terrainTex);
    for (auto& chunk : chunks) {
        if (chunk->dirty) chunk->build();
        chunk->render();
    }
}

void RubyDung::renderGame() {
    player->tick();

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluPerspective(70.0f, (float)WIDTH / HEIGHT, 0.1f, 512.0f);
    glMatrixMode(GL_MODELVIEW);

    glClearColor(0.5f, 0.8f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glLoadIdentity();

    glRotatef(player->xRot, 1, 0, 0);
    glRotatef(player->yRot, 0, 1, 0);
    glTranslatef(-player->x, -player->y, -player->z);

    drawChunks();
    drawCrosshair();
    drawHotbar();
}

void RubyDung::processInput() {
    if (glfwGetKey(window, GLFW_KEY_ESCAPE) == GLFW_PRESS) {
        glfwSetWindowShouldClose(window, true);
    }
}

void RubyDung::run() {
    double lastTime = glfwGetTime();
    int frameCount = 0;

    while (!glfwWindowShouldClose(window)) {
        processInput();

        if (state == MENU) {
            drawMenu();
        } else if (state == GAME) {
            renderGame();
        }

        glfwSwapBuffers(window);
        glfwPollEvents();

        double currentTime = glfwGetTime();
        frameCount++;
        if (currentTime - lastTime >= 1.0) {
            currentFps = frameCount / (currentTime - lastTime);
            frameCount = 0;
            lastTime = currentTime;
        }
    }
}

// === CMakeLists.txt ===
cmake_minimum_required(VERSION 3.15)
project(Nanocraft)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(OpenGL REQUIRED)
find_package(GLFW3 REQUIRED)
find_package(GLEW REQUIRED)
find_package(glm REQUIRED)
find_package(SDL2 REQUIRED)
find_package(SDL2_image REQUIRED)
find_package(ZLIB REQUIRED)

include_directories(${SDL2_INCLUDE_DIRS})

add_executable(nanocraft
    Main.cpp
    Chunk.cpp
    MinecraftJavaClient.cpp
    JavaLanServer.cpp
    RubyDung.cpp
)

target_link_libraries(nanocraft
    OpenGL::OpenGL
    GLFW::GLFW
    GLEW::GLEW
    glm::glm
    ${SDL2_LIBRARIES}
    ${SDL2_IMAGE_LIBRARIES}
    ZLIB::ZLIB
    pthread
)

if(WIN32)
    target_link_libraries(nanocraft ws2_32 wsock32)
endif()
